// COORDINATE ROUNDING — the user setting that selects the drag-rounding law.
//
// A drag that ends on a round number is easier to trust than one that ends on
// 0.2938174. The reference gives that to the user as a five-valued preference
// labelled "Coordinate Rounding", grouped with its other accuracy settings and
// repeated in its snapping popover; the value picks WHICH law computes the
// rounding step, and one of the five turns it off entirely.
//
// This module is the SELECTOR and nothing else: the enum, its wire names, the
// live value, and the persisted companion increment the two Fixed arms read.
// The LAW — what step each arm computes — lives in `drag.d` next to
// `viewWorldPerPixel`, because every arm is a function of that one number.
// Splitting policy from law is what lets `drag.d` stay a pure seam: it is
// handed a mode, it never reads a global.
//
// Why a leaf module rather than a member of `prefs.d` or `drag.d`: the enum is
// needed by `drag.d` (the law), `prefs.d` (persistence), `commands/` (the
// command), `registration.d` (the factory) and the transform tool (the call
// site). A leaf with no project imports lets all five reach it without anyone
// importing anyone else.
module coord_rounding;

// ---------------------------------------------------------------------------
// The setting
// ---------------------------------------------------------------------------

/// The reference's five values, in its own order — the integers ARE its wire
/// values, so a persisted file and a future arm both stay compatible.
///
/// What each one means is the reference's own help text, abridged:
///   None         no rounding at all; the raw screen-to-world transform.
///                Useful for working freehand.
///   Normal       clean, round coordinates based on the view transform; the
///                step gets smaller or larger as you zoom.
///   Fine         like Normal, but tuned so one pixel of mouse movement is
///                about one step of rounding. THE SHIPPED DEFAULT.
///   Fixed        the Fixed Increment setting puts a LOWER LIMIT on both the
///                rounding and the grid.
///   ForcedFixed  the input step matches the increment exactly, at any zoom.
///
/// Value-level provenance, stated per arm because it is not uniform:
///   * `Fine` is measured — 29 rows over a 1024x zoom range, 29 match, and it
///     is the arm every capture in this campaign ran under.
///   * `Normal` is decoded and confirmed by one live row.
///   * `None` is the `step <= 0` identity, which is the only gate on the
///     rounding path and is therefore exact by construction.
///   * `ForcedFixed` is decoded, and two independent decodes agree on it.
///   * `Fixed` is the ONE arm whose value-level form is an inference rather
///     than a measurement — see `axisDragSubStep` in `drag.d`.
enum CoordinateRounding : int {
    None        = 0,
    Normal      = 1,
    Fine        = 2,
    Fixed       = 3,
    ForcedFixed = 4,
}

/// The shipped default, and it is the reference's: rounding ON, at the
/// one-pixel step. A port that defaulted to `None` would be shipping the
/// term switched off and calling it ported.
enum CoordinateRounding kCoordRoundingDefault = CoordinateRounding.Fine;

/// The companion increment the two Fixed arms read, in world units. The
/// reference ships 0.01.
enum float kFixedIncrementDefault = 0.01f;

// Live values. Main-thread only, same stance as `popup_state` — the menu, the
// command and the drag call site all run on the main thread.
private __gshared CoordinateRounding g_mode  = kCoordRoundingDefault;
private __gshared float              g_fixed = kFixedIncrementDefault;

/// The live mode. Read at the drag call site on every motion event, NOT
/// frozen at the press: the reference pushes the preference into the view
/// every frame and re-derives the step on every zoom, so a mode change (or a
/// zoom) mid-drag takes effect immediately.
CoordinateRounding coordRounding() { return g_mode; }

/// The live fixed increment (world units). Non-positive is not clamped here —
/// the law's `step <= 0` guard turns it into the identity, which is the same
/// answer the reference gives.
///
/// That sentence was true of `ForcedFixed` and FALSE of `Fixed` until task
/// 0586: the `Fixed` arm used to return the view-derived sub-step for a
/// non-positive increment, so rounding stayed ON where the reference switches
/// it off. Both arms now reach the guard. Left unclamped rather than defended
/// here for the reason the sentence gives — the guard is the single gate, and
/// a second one would be a second place to keep in sync.
float coordRoundingFixedIncrement() { return g_fixed; }

/// Set the mode and republish the UI state paths. The only writer outside
/// startup/prefs load.
void setCoordRounding(CoordinateRounding m) {
    g_mode = m;
    publishCoordRoundingState();
}

/// Set the fixed increment (world units) and republish.
void setCoordRoundingFixedIncrement(float v) {
    g_fixed = v;
    publishCoordRoundingState();
}

/// Back to the shipped defaults. Called from `scene.reset` for the same
/// reason every toolpipe stage is reset there: without it, one test that
/// flips the mode corrupts every later test sharing the vibe3d process.
void resetCoordRounding() {
    g_mode  = kCoordRoundingDefault;
    g_fixed = kFixedIncrementDefault;
    publishCoordRoundingState();
}

// ---------------------------------------------------------------------------
// Names — the wire format for the command, prefs and the menu's `checked:`
// ---------------------------------------------------------------------------

/// Wire name (lowerCamel, stable): what `pref.coordRounding <name>` takes,
/// what prefs.json stores, and what the popover's `checked:` compares against.
string coordRoundingName(CoordinateRounding m) {
    final switch (m) {
        case CoordinateRounding.None:        return "none";
        case CoordinateRounding.Normal:      return "normal";
        case CoordinateRounding.Fine:        return "fine";
        case CoordinateRounding.Fixed:       return "fixed";
        case CoordinateRounding.ForcedFixed: return "forcedFixed";
    }
}

/// Parse a wire name. Returns false and leaves `m` ALONE on anything
/// unrecognized, so a hand-edited prefs.json or a typo'd command keeps the
/// current value rather than silently landing on `None` and switching the
/// term off.
///
/// `ref`, NOT `out`, and that is the whole point: D default-initializes an
/// `out` parameter on entry, and `CoordinateRounding.init` is `None` — so the
/// `out` spelling of this function switches the rounding OFF on every
/// rejected parse, which is exactly the failure it is written to prevent.
bool parseCoordRounding(string s, ref CoordinateRounding m) {
    switch (s) {
        case "none":        m = CoordinateRounding.None;        return true;
        case "normal":      m = CoordinateRounding.Normal;      return true;
        case "fine":        m = CoordinateRounding.Fine;        return true;
        case "fixed":       m = CoordinateRounding.Fixed;       return true;
        case "forcedFixed": m = CoordinateRounding.ForcedFixed; return true;
        default:                                                return false;
    }
}

/// Publish the live mode under `coordRounding/mode` so the snapping popover
/// can tick the active entry. Imported locally so this module keeps no
/// project-level imports at module scope (see the header).
void publishCoordRoundingState() {
    import popup_state : setStatePath;
    setStatePath("coordRounding/mode", coordRoundingName(g_mode));
}

// ---------------------------------------------------------------------------
