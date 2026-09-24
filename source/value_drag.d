module value_drag;

// ---------------------------------------------------------------------------
// The no-handle VALUE DRAG — one law, two quantisers (task 7122).
//
// Measured (`doc/measured_laws.md` §26, §27; fixture
// `tests/fixtures/editor_attrs_acen_laws_w17.json` → `value_drag`): a tool with
// no drawn handle that hauls one scalar reads ONLY the horizontal screen travel
// (right +), relative to the PRESS, with a gain set by the view's pixel size P
// and nothing else — not the anchor's depth, not the vertical travel. The tools
// differ only in how the travel becomes a value, so that is data here
// (`ValueDragLaw`), and `ValueDrag` is the one driver both tools call:
//
//   Linear  (Merge Points) — `v = v_press + gain·Δx`, Δx from the press pixel;
//           no accumulation, so no event granularity can move it.
//   Stepped (Inset)        — per pixel, `v = (round(v/step) + dir)·step`; a
//           pixel that lands EXACTLY (double ==) on a multiple of `detent`
//           makes the next `holdPx` pixels in the same direction do nothing;
//           a direction change clears the hold. Stateful per PIXEL, so an event
//           of n pixels is n steps (`steppedDragEvent`, capped per event).
//
// Both are signed while the button is held; whether the release keeps
// `max(0, last)` is the law's `keepNonNegative` bit (Merge: yes; Inset: no).
// The two tool laws are the two factories at the bottom — the only place the
// captured constants live.
// ---------------------------------------------------------------------------

import std.math : round, isFinite;

enum ValueDragQuantiser : ubyte { Linear, Stepped }

/// Pixels held after landing on a detent — 36 at every zoom (§27, C5-i-round).
enum int kValueDragDetentHoldPx = 36;

/// Kernel cap on the pixels one motion event may step (a teleporting cursor
/// or a hostile event log must not scale the per-pixel loop).
enum int MAX_VALUE_DRAG_PX_PER_EVENT = 1 << 14;

struct ValueDragLaw {
    ValueDragQuantiser quantiser;
    double gain   = 0;   // Linear: value units per pixel
    double step   = 0;   // Stepped: one pixel's step
    double detent = 0;   // Stepped: detent spacing (0 = none)
    int    holdPx = 0;   // Stepped: pixels held after a detent landing
    bool   keepNonNegative;

    static ValueDragLaw linear(double gain, bool keepNonNegative) nothrow @nogc {
        ValueDragLaw l;
        l.quantiser = ValueDragQuantiser.Linear;
        l.gain = isFinite(gain) ? gain : 0;
        l.keepNonNegative = keepNonNegative;
        return l;
    }

    // No guard here: `steppedDragPixel` refuses a non-positive or NaN step
    // and a detent that is not > 0, at the one place that consumes them.
    static ValueDragLaw stepped(double step, double detent,
            int holdPx = kValueDragDetentHoldPx) nothrow @nogc {
        ValueDragLaw l;
        l.quantiser = ValueDragQuantiser.Stepped;
        l.step = step; l.detent = detent; l.holdPx = holdPx;
        return l;
    }
}

/// One pixel of a stepped drag in direction `dir` (±1). Pure; `hold` and
/// `lastDir` carry the detent state between pixels.
double steppedDragPixel(double v, int dir, double step, double detent,
        int holdPx, ref int hold, ref int lastDir) nothrow @nogc {
    if (dir != lastDir) { hold = 0; lastDir = dir; }
    if (!(step > 0) || !isFinite(step)) return v;
    if (hold > 0) { --hold; return v; }
    v = (round(v / step) + dir) * step;
    if (detent > 0 && v == round(v / detent) * detent) hold = holdPx;
    return v;
}

/// `|dx|` pixels of a stepped drag (capped at MAX_VALUE_DRAG_PX_PER_EVENT);
/// returns the pixels actually stepped.
int steppedDragEvent(ref double v, int dx, double step, double detent,
        int holdPx, ref int hold, ref int lastDir) nothrow @nogc {
    const int dir = dx > 0 ? 1 : -1;
    const long mag = dx > 0 ? cast(long) dx : -cast(long) dx;
    const int n = mag > MAX_VALUE_DRAG_PX_PER_EVENT
        ? MAX_VALUE_DRAG_PX_PER_EVENT : cast(int) mag;
    foreach (i; 0 .. n)
        v = steppedDragPixel(v, dir, step, detent, holdPx, hold, lastDir);
    return n;
}

/// The per-gesture driver: `press` at the press pixel and value, `motion` per
/// event (horizontal pixel only), `release` for the value to keep.
struct ValueDrag {
    ValueDragLaw law;
    int    pressX, lastX;
    double pressValue = 0, value = 0;
    int    hold, lastDir;
    int    lastStepped;   // pixels the last stepped event actually stepped

    void press(int x, double v, ValueDragLaw l) nothrow @nogc {
        law = l; pressX = lastX = x; pressValue = value = v;
        hold = 0; lastDir = 0; lastStepped = 0;
    }

    double motion(int x) nothrow @nogc {
        final switch (law.quantiser) {
            case ValueDragQuantiser.Linear:
                value = pressValue + law.gain * (cast(double) x - pressX);
                break;
            case ValueDragQuantiser.Stepped:
                lastStepped = steppedDragEvent(value, x - lastX, law.step,
                    law.detent, law.holdPx, hold, lastDir);
                break;
        }
        lastX = x;
        return value;
    }

    double release() nothrow @nogc {
        if (law.keepNonNegative && value < 0) value = 0;
        return value;
    }
}

// --- the two captured tool laws ---------------------------------------------
// `pixelSize` is `drag.viewWorldPerPixel` of the view the press landed in;
// `worldPerLocal` converts the world law into the layer's LOCAL units the
// kernel means (task 0645, `OverlaySpace.meanWorldPerLocal`; 1 on every
// captured rig).

/// Merge Points (§26): `0.05·P` per pixel, kept as max(0, last).
ValueDragLaw mergeValueDragLaw(double pixelSize, double worldPerLocal) nothrow @nogc {
    return ValueDragLaw.linear(0.05 * pixelSize / worldPerLocal, true);
}

/// Inset (§27): step = the {1,2,5}·10^k ceiling of 0.2·P, detent = the
/// {1,2,5}·10^k nearest (log10) to 20·P, hold 36 px, signed after release.
ValueDragLaw insetValueDragLaw(double pixelSize, double worldPerLocal) {
    import drag : stepLadderCeil, stepLadderNearest;
    return ValueDragLaw.stepped(stepLadderCeil(0.2 * pixelSize) / worldPerLocal,
        stepLadderNearest(20.0 * pixelSize) / worldPerLocal);
}
