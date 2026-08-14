// Module unittests for `viewport_scheme`, moved verbatim out of source/viewport_scheme.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.viewport_scheme_test;

import math : Vec3;
import std.algorithm.comparison : max, min;
import std.math : abs;
import viewport_scheme;

/// Every role resolves to a real colour.
///
/// This is the NaN guard the indexed initialiser needs: add a role to
/// `SchemeColor` and forget its row and the slot stays `float.init` = NaN,
/// which no other test would notice — it builds, it draws, it is simply
/// invisible. Checking `c == c` catches exactly that.
unittest {
    // Compile-time foreach over the member-name sequence (no array literal, or
    // `roleName` would be a runtime variable and unusable in the lookup).
    foreach (roleName; __traits(allMembers, SchemeColor)) {
        const c = schemeColor(__traits(getMember, SchemeColor, roleName));
        assert(c.x == c.x && c.y == c.y && c.z == c.z,
            "SchemeColor." ~ roleName ~ " has no value in kSchemeDefaults "
            ~ "(NaN slot left by the indexed initialiser)");
        assert(c.x >= 0.0f && c.x <= 1.0f
            && c.y >= 0.0f && c.y <= 1.0f
            && c.z >= 0.0f && c.z <= 1.0f,
            "SchemeColor." ~ roleName ~ " is outside [0,1]");
    }
}

/// The pinned values.
///
/// The expected side is written out INDEPENDENTLY of the table rather than
/// read back from it — a test that says `schemeColor(axisY) == kSchemeDefaults
/// [axisY]` passes no matter what either one says. These literals are the
/// scheme as measured; an edit that drifts a channel has to change this list
/// too, and changing this list is the moment to ask whether the measurement
/// moved or the fingers slipped.
unittest {
    static struct Row { SchemeColor role; float r, g, b; string what; }
    // dfmt off
    immutable Row[] pinned = [
        Row(SchemeColor.axisX,        0.9f,  0.2f,  0.2f,  "X axis"),
        Row(SchemeColor.axisY,        0.2f,  0.8f,  0.2f,  "Y axis — 0.8 green, NOT 0.9"),
        Row(SchemeColor.axisZ,        0.2f,  0.4f,  1.0f,  "Z axis — a light blue with a green lift, NOT pure dark blue"),
        Row(SchemeColor.handle,       0.4f,  1.0f,  1.0f,  "idle axis-less handle"),
        Row(SchemeColor.handleActive, 1.0f,  0.9f,  0.4f,  "the GRABBED handle"),
        Row(SchemeColor.handleGuide,  0.8f,  0.6f,  1.0f,  "drag guide / ring pointer marker"),
        Row(SchemeColor.handleCage,   0.4f,  0.8f,  0.6f,  "vertex-normal cage"),
        Row(SchemeColor.handleLabel,  0.8f,  0.8f,  0.8f,  "dimension + handle labels"),
        Row(SchemeColor.handleUnsnap, 0.9f,  0.7f,  1.0f,  "unsnapped cursor marker"),
        Row(SchemeColor.backdrop,     0.36f, 0.40f, 0.45f, "viewport backdrop"),
        Row(SchemeColor.selection,    1.0f,  0.66f, 0.16f, "MESH selection — never a handle"),
        Row(SchemeColor.preHighlight, 0.549f, 0.710f, 0.780f,
            "the thing under the pointer — NOT the face-specific tint (0.5, 0.71, 0.79)"),
    ];
    // dfmt on
    foreach (p; pinned) {
        const c = schemeColor(p.role);
        assert(c.x == p.r && c.y == p.g && c.z == p.b,
            "scheme colour drifted: " ~ p.what);
    }
}

/// The three states, and the two colours they resolve to.
unittest {
    const idle   = schemeColor(SchemeColor.axisX);
    const active = schemeColor(SchemeColor.handleActive);

    // Idle keeps its own colour...
    assert(handleColor(idle, HandlePaint.idle) == idle);
    // ...and BOTH the pointer resting on it and a haul take the active colour,
    // whatever the handle's own colour is. This is the measured equality that
    // makes hover and grab indistinguishable everywhere except the plane ring.
    assert(handleColor(idle, HandlePaint.hover)   == active);
    assert(handleColor(idle, HandlePaint.grabbed) == active);
    assert(handleColor(schemeColor(SchemeColor.handle), HandlePaint.grabbed) == active);

    // The active colour is NOT the mesh-selection colour. We used to paint a
    // "selected" handle with the selection orange; that orange belongs to
    // selected geometry and never to a handle, and the two must stay distinct
    // or the gizmo starts speaking the mesh's language.
    assert(active != schemeColor(SchemeColor.selection));

    // ...nor the hand-picked yellow the pre-measurement hover state wore. The
    // state turned out to be real; the colour it was given was not.
    immutable Vec3 retiredRolloverYellow = Vec3(1.0f, 0.95f, 0.15f);
    immutable Vec3 retiredSelectedOrange = Vec3(1.0f, 0.64f, 0.0f);
    assert(active != retiredRolloverYellow);
    assert(active != retiredSelectedOrange);
}

/// The plane handle's ring: lights under the pointer, DARKENS under the grab.
///
/// This is the assertion that stops the enum being collapsed back to a bool.
/// A two-state law can only make `grabbed` agree with `hover` (which breaks
/// the third row) or with `idle` (which breaks the second); the three rows
/// below are mutually unsatisfiable by any function of one boolean, so this
/// test fails on the spot if someone re-derives `paint` from `engaged` alone.
unittest {
    const axis   = schemeColor(SchemeColor.axisZ);   // the XY plane's normal
    const active = schemeColor(SchemeColor.handleActive);

    assert(planeRingColor(axis, HandlePaint.idle)    == axis);
    assert(planeRingColor(axis, HandlePaint.hover)   == active);
    assert(planeRingColor(axis, HandlePaint.grabbed) == axis);

    // Non-monotonic, stated as such: the ring is NOT "more highlighted the
    // more you interact with it". Hover is the odd one out.
    assert(planeRingColor(axis, HandlePaint.idle)
           == planeRingColor(axis, HandlePaint.grabbed));
    assert(planeRingColor(axis, HandlePaint.hover)
           != planeRingColor(axis, HandlePaint.grabbed));

    // And the exception is exactly one part wide: the disc inside that ring
    // follows the common law, so hover and grab agree there. Ring and disc
    // therefore DISAGREE about a grab, which is the whole two-part effect.
    const disc = planeFillColor(axis);
    assert(handleColor(disc, HandlePaint.hover) == handleColor(disc, HandlePaint.grabbed));
    assert(handleColor(disc, HandlePaint.grabbed) != planeRingColor(axis, HandlePaint.grabbed));

    // The three axes all break the same way — nothing here is X-specific.
    foreach (ax; 0 .. 3) {
        const a = axisColor(ax);
        assert(planeRingColor(a, HandlePaint.hover) == active);
        assert(planeRingColor(a, HandlePaint.grabbed) == a);
    }
}

/// The item law: four states, three colours, and the third one is DERIVED.
///
/// The expected side of the third row is written as the expression, not as the
/// triple it evaluates to — same discipline as `rotateBackingDiscColor`'s test,
/// and for the same reason: the triple is what a literal would freeze, and
/// freezing it is the bug the derivation exists to prevent. The 8-bit values
/// the shipped scheme lands on are stated separately, as a statement about
/// THIS scheme.
unittest {
    const sel  = schemeColor(SchemeColor.selection);
    const pre  = schemeColor(SchemeColor.preHighlight);

    // The two booleans map onto the four states, and nothing collapses.
    assert(itemHighlight(false, false) == ItemHighlight.none);
    assert(itemHighlight(false, true)  == ItemHighlight.hovered);
    assert(itemHighlight(true,  false) == ItemHighlight.selected);
    assert(itemHighlight(true,  true)  == ItemHighlight.selectedHovered);

    // Row 1 and row 2 are lookups, and they are DIFFERENT lookups. This is the
    // question the capture existed to answer — "hover just draws it as
    // selected" was a live hypothesis and it is false.
    assert(itemHighlightColor(ItemHighlight.hovered)  == pre);
    assert(itemHighlightColor(ItemHighlight.selected) == sel);
    assert(pre != sel);

    // Row 3, as the relationship rather than as a value.
    const sh = itemHighlightColor(ItemHighlight.selectedHovered);
    assert(sh.x == min(1.0f, sel.x + kItemHoverBrighten));
    assert(sh.y == min(1.0f, sel.y + kItemHoverBrighten));
    assert(sh.z == min(1.0f, sel.z + kItemHoverBrighten));

    // …and it is a THIRD colour, not either of the two it sits between. A
    // three-state implementation passes every assertion above except these.
    assert(sh != sel);
    assert(sh != pre);

    // The clamp. The shipped selection colour saturates its red channel, so
    // this is exercised by the real scheme and not only in principle: 1.0 + 0.1
    // must read back as 1.0, not 1.1 — a value that would silently truncate on
    // its way to the framebuffer and hide the missing clamp.
    assert(sel.x == 1.0f && sh.x == 1.0f);

    // What the shipped scheme lands on, in the units the capture recorded.
    // Byte conversion is round-to-nearest, matching the framebuffer's.
    static int toByte(float f) {
        immutable v = cast(int)(f * 255.0f + 0.5f);
        return v < 0 ? 0 : (v > 255 ? 255 : v);
    }
    assert(toByte(pre.x) == 140 && toByte(pre.y) == 181 && toByte(pre.z) == 199);
    assert(toByte(sel.x) == 255 && toByte(sel.y) == 168 && toByte(sel.z) == 41);
    assert(toByte(sh.x)  == 255 && toByte(sh.y)  == 194 && toByte(sh.z)  == 66);

    // The generic pre-highlight row is NOT the face-specific tint that
    // `mesh_gpu.drawFacesHighlighted` paints a hovered polygon with. The
    // capture drove the face row onto magenta and no item-mode hover paint
    // ever turned magenta, so an implementation that reused the face literal
    // here would be reading the wrong preference. They differ by 12 counts on
    // red and 3 on blue, which is nothing to the eye and everything to a lever.
    immutable Vec3 facePreHighlight = Vec3(0.5f, 0.71f, 0.79f);
    assert(pre != facePreHighlight);
}

/// Axis lookup agrees with the table, and plane fills track their outline.
unittest {
    assert(axisColor(0) == schemeColor(SchemeColor.axisX));
    assert(axisColor(1) == schemeColor(SchemeColor.axisY));
    assert(axisColor(2) == schemeColor(SchemeColor.axisZ));

    // The fill is strictly darker than the outline on every populated channel,
    // so the disc always reads as "inside the ring" and never as a second ring.
    foreach (ax; 0 .. 3) {
        const o = axisColor(ax);
        const f = planeFillColor(o);
        assert(f.x <= o.x && f.y <= o.y && f.z <= o.z);
        assert(f.x < o.x || f.y < o.y || f.z < o.z);
    }
}

/// The Solid fill stays anchored where task 0592 put it.
unittest {
    // Restated rather than derived, same reason as the pinned table above.
    enum float kMeasuredSchemeFill = 0.6f;
    enum float kOursWas0589        = 0.8f;   // LitShader's material grey, superseded
    static assert(kMeasuredSchemeFill != kOursWas0589,
        "the two anchors must differ or nothing here discriminates");
    assert(kSchemeSolidFill == kMeasuredSchemeFill);
}

/// The rotate backing disc is a DERIVATION, and the test says so.
///
/// The expected side is written as `backdrop - 0.15` rather than as the triple
/// that comes out of it, on purpose: the triple is what a literal would have
/// frozen, and freezing it is the bug this function exists to prevent. So the
/// first assertion re-derives, and only the second one names (0.21, 0.25, 0.30)
/// — as a statement about the SHIPPED backdrop, which is what was measured.
unittest {
    const b = schemeColor(SchemeColor.backdrop);
    const d = rotateBackingDiscColor();

    // The relationship, stated without reference to any particular backdrop.
    assert(d.x == b.x - kBackingDiscDarken);
    assert(d.y == b.y - kBackingDiscDarken);
    assert(d.z == b.z - kBackingDiscDarken);

    // ...and the value it lands on today. If the backdrop is ever re-themed
    // this row is the one that has to move, and the three above must not.
    assert(abs(d.x - 0.21f) < 1e-6f);
    assert(abs(d.y - 0.25f) < 1e-6f);
    assert(abs(d.z - 0.30f) < 1e-6f);

    // Strictly darker than the backdrop on every channel — the whole point of
    // the shape. A disc at or above the backdrop is not a backing disc.
    assert(d.x < b.x && d.y < b.y && d.z < b.z);

    // NOT black, which is what it used to be. Stated explicitly because black
    // is a perfectly plausible-looking value for a "backing" shape and the
    // reason it is wrong is not visible from the code: at the outline's 0.75 it
    // composites to a quarter of the backdrop, i.e. a heavy dark stroke, where
    // the derived colour composites to the backdrop minus 0.1125.
    assert(d != Vec3(0.0f, 0.0f, 0.0f));

    // The clamp. Not reachable from the shipped backdrop, so nothing else here
    // exercises it; a channel darker than the offset must floor at 0 rather
    // than going negative and being multiplied into a blend.
    static assert(kBackingDiscDarken > 0.0f);
    assert(max(0.0f, 0.10f - kBackingDiscDarken) == 0.0f);
}

/// The fixed constants are fixed.
unittest {
    assert(kViewRingGrey    == Vec3(0.6f, 0.6f, 0.6f));
    assert(kHandleGhostGrey == Vec3(0.3f, 0.3f, 0.3f));
    // The view ring must not be mistakable for an axis: it belongs to none.
    foreach (ax; 0 .. 3)
        assert(kViewRingGrey != axisColor(ax));
}
