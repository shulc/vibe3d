module tool_input;

// ---------------------------------------------------------------------------
// Centralized tool-input / modifier dispatch — the MECHANISM (Phase 1 of
// doc/tool_input_dispatch_design.md). Pure, host-free: no GL, and the only
// two functions that mention SDL at all (toButton/toMods, at the bottom) are
// tiny type-conversion adapters — everything above them is plain D and is
// exercised entirely by the unittest blocks in this module, with no SDL
// runtime call and no live vibe3d instance required.
//
// This module is ADDITIVE + INERT on its own: nothing in the tree calls
// resolveToolAction/resolveResetScope yet (that's Tool's dispatchInput seam,
// source/tool.d), and no tool provides a non-empty bindings() table yet (that
// is a later migration phase). Landing this module changes no observable
// behavior.
//
// Problem this replaces: today a tool that wants a button×modifier grid
// hand-rolls it twice — a DOWN-side classifier (a `final switch` over raw
// button + modifier reads) and a separate UP-side cascade that has to
// re-derive "which action is currently armed" from a fixed priority order
// over its own bool flags. The DOWN classifier is fine; the UP re-derivation
// is where bugs live — a new mode's UP branch can end up shadowed by an
// earlier per-button early-return (a whole mode becomes unreachable), and
// because "what's armed" isn't tracked per physical button, a reset wired to
// one button's DOWN can clobber a gesture that's mid-drag on a DIFFERENT
// button, forcing a hand-carved reset exception that nothing enforces.
//
// Fix: make BOTH sides read from ONE typed source of truth.
//   - `resolveToolAction` (below) is the DOWN-side classifier as a pure
//     function over a declarative table, instead of a switch buried in one
//     tool. It is the ONLY place the "Alt is never a tool binding — camera
//     nav owns it" rule is written.
//   - `Tool.dispatchInput` (source/tool.d) is the per-button state machine
//     that arms the RESOLVED action on Down and reads back that SAME id on
//     Up — never re-derived from flag priority — so a new mode is one table
//     row + one case, reachable by construction, and each physical button
//     tracks its own armed action so a chord on one button structurally
//     cannot clear a different button's in-progress gesture.
// ---------------------------------------------------------------------------

/// Abstract action id a tool resolves a (button, modifier) combo to. Each
/// tool owns its own small action space (typically its own `enum : ToolAction
/// { ... }`) rather than sharing one global enum — the resolver and
/// dispatcher only ever move this value around, they never interpret it, so
/// staying a plain `int` keeps them generic across every tool's action set.
alias ToolAction = int;

/// The sentinel every unresolved combo yields: "not this tool's — let the
/// caller's normal fallback (e.g. camera navigation) handle it." A tool's
/// `onMouseButtonDown`/`onMouseButtonUp` override returning `false` for this
/// value is what lets the existing tools-then-handlers-then-camera pipeline
/// keep working unchanged.
enum ToolAction PassThrough = -1;

/// Gesture phase, mirroring the existing SDL Down/Move/Up flow but decoupled
/// from any SDL type so the resolver/dispatcher stay unit-testable without
/// SDL.
enum InputPhase { Down, Move, Up }

/// Which physical mouse button, engine-neutral (mirrors the SDL left/middle/
/// right ordering so `toButton` below is a trivial mapping). `None` is the
/// sentinel for a physical button with NO neutral mapping — a 4th/5th mouse
/// button (SDL X1/X2) `toButton` cannot classify. It is deliberately the LAST
/// member so `Left`/`Middle`/`Right` keep indices 0/1/2 (the width of
/// `Tool.armed_`); `dispatchInput` declines `None` up front and so never
/// indexes `armed_[]` with it. A `None` press binds to no `InputBinding` row
/// (no table lists it) and resolves to `PassThrough`.
enum InputButton : ubyte { Left, Middle, Right, None }

/// A small modifier bitset, deliberately NOT `SDL_Keymod` — keeping it a
/// plain `ubyte` bitset is what lets `resolveToolAction` and its table be
/// exercised with bare integers, no SDL import, no running app.
enum InputMod : ubyte { None = 0, Shift = 1, Ctrl = 2, Alt = 4 }

/// Every modifier bit `resolveToolAction` considers. Any other bit an SDL
/// keymod might carry (Num Lock, Caps Lock, GUI, ...) is masked away before
/// matching.
private enum ubyte AllMods = InputMod.Shift | InputMod.Ctrl | InputMod.Alt;

/// When the action THIS row resolves to arms at Down, does it also signal
/// the tool to clear its OWN seed state via `Tool.onInputResetAll`?
///   - `SelfButton` (default, and correct for nearly every binding): only
///     this row's OWN button slot gets (re-)armed; `onInputResetAll` is not
///     called, and — same as every other row — no OTHER button's armed
///     action is ever touched. This is what makes "which action is armed on
///     which button" a per-button fact instead of a single shared set of
///     flags that has to be reset all-or-nothing.
///   - `AllButtons`: additionally fires `Tool.onInputResetAll()` — a hook for
///     whatever per-gesture seed state the TOOL ITSELF keeps — before arming
///     THIS row's button slot. Reserved for a combo that is DELIBERATELY a
///     full reset of the tool's own state (e.g. external history navigation
///     moving the mesh out from under an in-progress gesture) — a decision a
///     binding row states as data, not a hand-placed call buried in a
///     specific handler.
///
/// Neither value EVER clears a DIFFERENT button's `armed_` slot — not even
/// `AllButtons` (despite the name: it means "reset the tool's state fully",
/// not "clear every button's arm"). `dispatchInput`'s per-button isolation
/// is REQUIRED for the two-button-chord property (a chord on one button must
/// never cancel a gesture in progress on another — see the chord unittest in
/// `tool.d`) and must hold regardless of `ResetScope`. To drop every
/// button's armed action in one call, use `Tool.resetAllArmed()` instead —
/// a distinct seam for external resync, not a `ResetScope`.
enum ResetScope { SelfButton, AllButtons }

/// One row of a tool's declarative (button, exact-modifier-combo) → action
/// grid. A tool provides its whole grid as `const(InputBinding)[] bindings()`
/// (an array literal, in-code — this is tool-specific behavior data, not
/// user-facing config, so it lives next to the tool like `params()`/`flags()`
/// already do, not in a YAML preset).
struct InputBinding {
    InputButton button;
    ubyte       modMask;                       // exact match against AllMods
    ToolAction  action;
    ResetScope  reset = ResetScope.SelfButton;
}

/// Find the row (button, mods) matches, or `null`. `mods` must already be
/// masked to `AllMods` by the caller — both public resolvers below do this
/// before calling in, so this helper stays a bare exact-match scan.
private const(InputBinding)* findBinding(const(InputBinding)[] table, InputButton button, ubyte mods) {
    foreach (ref row; table)
        if (row.button == button && row.modMask == mods) return &row;
    return null;
}

/// The single central classifier: physical (button, raw modifier bits) →
/// abstract action id. Pure, stateless, allocation-free — first exact match
/// in `table` wins; anything the table doesn't cover (including an empty
/// table) answers `PassThrough`.
///
/// Alt is hard-blocked ABOVE the table scan, not merely omitted from tables:
/// no `InputBinding` row can ever bind an Alt combo through this function,
/// so "Alt = camera navigation, never a tool" is enforced here once instead
/// of being a convention every tool's table has to independently uphold.
ToolAction resolveToolAction(const(InputBinding)[] table, InputButton button, ubyte mods) {
    immutable m = mods & AllMods;
    if ((m & InputMod.Alt) != 0) return PassThrough;
    auto row = findBinding(table, button, m);
    return row is null ? PassThrough : row.action;
}

/// The `ResetScope` the row `resolveToolAction` would pick for (button,
/// mods) declares. `SelfButton` for anything unbound (Alt combos included) —
/// a combo that doesn't arm anything has no reset behavior to speak of, and
/// `SelfButton` is the harmless value (it only ever clears the SAME slot
/// `dispatchInput` is about to (re)arm anyway).
ResetScope resolveResetScope(const(InputBinding)[] table, InputButton button, ubyte mods) {
    immutable m = mods & AllMods;
    if ((m & InputMod.Alt) != 0) return ResetScope.SelfButton;
    auto row = findBinding(table, button, m);
    return row is null ? ResetScope.SelfButton : row.reset;
}

// ---------------------------------------------------------------------------
// SDL adapters — the ONLY two functions in this module that reference SDL
// types, and only as plain value conversions (no SDL call, no global state
// read). A tool that opts into `Tool.dispatchInput` calls these at the SDL
// boundary (`toButton(e.button)`, `toMods(SDL_GetModState())`); everything
// above this line never sees an SDL type.
// ---------------------------------------------------------------------------

import bindbc.sdl : SDL_Keymod, KMOD_SHIFT, KMOD_CTRL, KMOD_ALT,
                     SDL_BUTTON_LEFT, SDL_BUTTON_MIDDLE, SDL_BUTTON_RIGHT;

/// SDL's raw `button` field (`SDL_BUTTON_LEFT`/`_MIDDLE`/`_RIGHT`) → the
/// neutral `InputButton`. Any other physical button — a 4th/5th mouse button
/// (SDL X1/X2) — maps to `InputButton.None`, NOT `Left`: aliasing an unknown
/// button to `Left` would make it fire whatever a tool bound to plain LEFT
/// (e.g. a place/move gesture), and would let its `ResetScope` clobber an
/// in-flight LEFT gesture. `None` binds to no row, so `dispatchInput` declines
/// it — the pre-dispatch behavior where such buttons were simply ignored.
InputButton toButton(ubyte sdlButton) {
    switch (sdlButton) {
        case SDL_BUTTON_LEFT:   return InputButton.Left;
        case SDL_BUTTON_MIDDLE: return InputButton.Middle;
        case SDL_BUTTON_RIGHT:  return InputButton.Right;
        default:                return InputButton.None;
    }
}

/// SDL's live keymod bitset → the neutral `InputMod` bitset `resolveToolAction`
/// matches against.
ubyte toMods(SDL_Keymod mods) {
    ubyte m = 0;
    if (mods & KMOD_SHIFT) m |= InputMod.Shift;
    if (mods & KMOD_CTRL)  m |= InputMod.Ctrl;
    if (mods & KMOD_ALT)   m |= InputMod.Alt;
    return m;
}

// ---------------------------------------------------------------------------
// Unit tests — the whole point of pulling this logic out of a single tool:
// exercised as bare data, no SDL/GL, no live vibe3d instance.
// ---------------------------------------------------------------------------

version(unittest) {
    private enum : ToolAction { ActionA = 0, ActionB = 1, ActionC = 2 }

    private immutable InputBinding[] sampleTable = [
        InputBinding(InputButton.Left,   InputMod.None,               ActionA),
        InputBinding(InputButton.Left,   InputMod.Shift,              ActionB),
        InputBinding(InputButton.Middle, InputMod.Ctrl,               ActionC, ResetScope.AllButtons),
        InputBinding(InputButton.Right,  InputMod.Shift | InputMod.Ctrl, ActionB),
    ];
}

// Exact match: each bound (button, mods) resolves to its own action.
unittest {
    assert(resolveToolAction(sampleTable, InputButton.Left, InputMod.None) == ActionA);
    assert(resolveToolAction(sampleTable, InputButton.Left, InputMod.Shift) == ActionB);
    assert(resolveToolAction(sampleTable, InputButton.Middle, InputMod.Ctrl) == ActionC);
    assert(resolveToolAction(sampleTable, InputButton.Right, InputMod.Shift | InputMod.Ctrl) == ActionB);
}

// Exact match is EXACT, not a subset test: a row bound to plain Ctrl+MMB does
// NOT match a plain MMB press (Ctrl bit differs), and vice versa.
unittest {
    assert(resolveToolAction(sampleTable, InputButton.Middle, InputMod.None) == PassThrough);
    assert(resolveToolAction(sampleTable, InputButton.Middle, InputMod.Ctrl | InputMod.Shift) == PassThrough);
    // A row bound to plain LMB does not match Ctrl+LMB.
    assert(resolveToolAction(sampleTable, InputButton.Left, InputMod.Ctrl) == PassThrough);
}

// Unbound (button, mods) combos fall through to PassThrough.
unittest {
    assert(resolveToolAction(sampleTable, InputButton.Right, InputMod.None) == PassThrough);
    assert(resolveToolAction(sampleTable, InputButton.Right, InputMod.Ctrl) == PassThrough);
}

// ANY Alt combo resolves to PassThrough, even one a (malformed) table binds —
// Alt is structurally reserved for camera navigation, checked BEFORE the
// table scan.
unittest {
    immutable InputBinding[] tableWithAlt = [
        InputBinding(InputButton.Left, InputMod.Alt, ActionA),
    ];
    assert(resolveToolAction(tableWithAlt, InputButton.Left, InputMod.Alt) == PassThrough);
    assert(resolveToolAction(sampleTable, InputButton.Left, InputMod.Alt) == PassThrough);
    assert(resolveToolAction(sampleTable, InputButton.Middle, InputMod.Alt | InputMod.Ctrl) == PassThrough);
    assert(resolveToolAction(sampleTable, InputButton.Right, InputMod.Alt | InputMod.Shift | InputMod.Ctrl) == PassThrough);
}


// resolveResetScope mirrors resolveToolAction's matching, and reports the
// bound row's declared scope (defaulting to SelfButton for anything
// unbound).
unittest {
    assert(resolveResetScope(sampleTable, InputButton.Left, InputMod.None) == ResetScope.SelfButton);
    assert(resolveResetScope(sampleTable, InputButton.Middle, InputMod.Ctrl) == ResetScope.AllButtons);
    assert(resolveResetScope(sampleTable, InputButton.Right, InputMod.None) == ResetScope.SelfButton);
    assert(resolveResetScope(sampleTable, InputButton.Left, InputMod.Alt) == ResetScope.SelfButton);
}

// toButton / toMods — the SDL-boundary adapters.
unittest {
    assert(toButton(SDL_BUTTON_LEFT) == InputButton.Left);
    assert(toButton(SDL_BUTTON_MIDDLE) == InputButton.Middle);
    assert(toButton(SDL_BUTTON_RIGHT) == InputButton.Right);
    // Extra physical buttons (SDL X1=4 / X2=5, and any other unmapped code)
    // report None, NOT Left — an unknown button must not fire a plain-LEFT
    // binding. A None press then resolves to PassThrough (no table row lists
    // it), so dispatchInput declines it exactly as the pre-dispatch code
    // ignored buttons ≥ 4.
    assert(toButton(cast(ubyte)4) == InputButton.None);
    assert(toButton(cast(ubyte)5) == InputButton.None);
    assert(toButton(cast(ubyte)0) == InputButton.None);
    assert(resolveToolAction(sampleTable, InputButton.None, InputMod.None) == PassThrough);
    assert(resolveResetScope(sampleTable, InputButton.None, InputMod.None) == ResetScope.SelfButton);

    assert(toMods(cast(SDL_Keymod)0) == InputMod.None);
    assert(toMods(KMOD_SHIFT) == InputMod.Shift);
    assert(toMods(KMOD_CTRL) == InputMod.Ctrl);
    assert(toMods(cast(SDL_Keymod)(KMOD_SHIFT | KMOD_CTRL)) == (InputMod.Shift | InputMod.Ctrl));
    assert(toMods(KMOD_ALT) == InputMod.Alt);
}
