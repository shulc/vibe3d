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

import std.math : isFinite;

enum ValueDragQuantiser : ubyte { Linear }

struct ValueDragLaw {
    ValueDragQuantiser quantiser;
    double gain   = 0;   // Linear: value units per pixel
    bool   keepNonNegative;

    static ValueDragLaw linear(double gain, bool keepNonNegative) nothrow @nogc {
        ValueDragLaw l;
        l.quantiser = ValueDragQuantiser.Linear;
        l.gain = isFinite(gain) ? gain : 0;
        l.keepNonNegative = keepNonNegative;
        return l;
    }

}

/// The per-gesture driver: `press` at the press pixel and value, `motion` per
/// event (horizontal pixel only), `release` for the value to keep.
struct ValueDrag {
    ValueDragLaw law;
    int    pressX, lastX;
    double pressValue = 0, value = 0;

    void press(int x, double v, ValueDragLaw l) nothrow @nogc {
        law = l; pressX = lastX = x; pressValue = value = v;
    }

    double motion(int x) nothrow @nogc {
        final switch (law.quantiser) {
            case ValueDragQuantiser.Linear:
                value = pressValue + law.gain * (cast(double) x - pressX);
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
