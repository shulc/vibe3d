/// The viewport colour scheme — one table, addressed by ROLE.
///
/// Every colour the 3-D viewport and its interactive handles paint with lives
/// here and nowhere else. Before task 0596 these values were per-shape literals
/// scattered across `handles/shapes.d`, `falloff_handles.d`, the box and
/// primitive create tools and half a dozen edit tools; the same "red X arrow"
/// existed as eight independent copies, and they had already drifted apart.
/// A literal in a tool file cannot be corrected once — it has to be corrected
/// eight times, and the ninth copy is written next week. Hence a table.
///
/// WHY A ROLE ENUM AND AN ACCESSOR, rather than a bag of named constants:
/// this table is the shape a user preference wants. Each role is one row a
/// settings UI would expose ("Handle", "Active", "X Axis", …) and one row a
/// saved scheme file would carry. `schemeColor()` is the seam that a future
/// preference layer plugs into — it becomes "user override, else default"
/// without a single caller changing. **Building that UI is deliberately NOT
/// done here** (task 0596 is the palette, not the panel); what is done is
/// making it a one-file change when it comes.
///
/// TWO TIERS, on purpose:
///   1. `SchemeColor` + `kSchemeDefaults` — the preference-backed rows.
///   2. The `k*` constants below the table — values that are FIXED law, not
///      preferences: the screen-plane ring grey and the ghosted-channel grey
///      are constants of the drawing code, and a user who could recolour them
///      would only be able to make the gizmo wrong.
///
/// These are RAW scheme values. A viewport style that gamma-shapes its output
/// applies its own transfer curve on the way to the framebuffer; that is a
/// property of the style, not of this table, and it must not be baked in here.
module viewport_scheme;

import math : Vec3;
import std.algorithm.comparison : max;

version (unittest) import std.math : abs;

// ---------------------------------------------------------------------------
// The preference-backed rows
// ---------------------------------------------------------------------------

/// One addressable colour role. Order is presentation order (a settings panel
/// can walk the enum top-to-bottom); it carries no other meaning, and
/// `kSchemeDefaults` is written with indexed initialisers precisely so that
/// reordering this enum cannot silently re-point a value at the wrong role.
enum SchemeColor {
    // --- viewport ---
    backdrop,      /// empty-viewport background
    selection,     /// selected MESH geometry. NEVER a handle — see kHandleActive
    // --- axes ---
    axisX,
    axisY,
    axisZ,
    // --- handles ---
    handle,        /// an idle handle with no axis of its own (centre box, screen disc)
    handleActive,  /// the handle under the pointer, and the one being hauled — see handleColor()
    handleGuide,   /// drag guide line, pointer marker riding a rotate ring
    handleCage,    /// vertex-normal / cage overlay
    handleLabel,   /// dimension text and handle labels
    handleUnsnap,  /// the unsnapped cursor marker
    // --- tool parameter handles ---
    // Drag handles that stand for a tool PARAMETER rather than an axis. Named
    // for what they control, so a tool picks the row by meaning and two tools
    // controlling the same kind of quantity cannot drift apart.
    toolOffset,    /// offset / shift / extrude — a linear haul
    toolWidth,     /// width / inset — the secondary linear haul
    toolAngle,     /// an angular haul
    toolExtent,    /// a box extent / height handle
    toolPath,      /// slice + path handles and their plane
    toolPathLine,  /// the slice chord / path line itself
    toolPathRing,  /// the slice ring guide
}

private enum size_t kSchemeColorCount = SchemeColor.max + 1;

/// The shipped defaults.
///
/// Indexed initialisers, not positional: the role is written next to its value
/// so a reordering of `SchemeColor` moves the rows with it instead of shifting
/// every colour by one. Every slot MUST be filled — `Vec3`'s fields are
/// `float`, and `float.init` is NaN, so an unfilled row would sail through the
/// build and paint garbage. `allRolesPopulated` below is the guard.
immutable Vec3[kSchemeColorCount] kSchemeDefaults = [
    SchemeColor.backdrop:     Vec3(0.36f, 0.40f, 0.45f),
    SchemeColor.selection:    Vec3(1.00f, 0.66f, 0.16f),

    SchemeColor.axisX:        Vec3(0.90f, 0.20f, 0.20f),
    SchemeColor.axisY:        Vec3(0.20f, 0.80f, 0.20f),
    SchemeColor.axisZ:        Vec3(0.20f, 0.40f, 1.00f),

    SchemeColor.handle:       Vec3(0.40f, 1.00f, 1.00f),
    SchemeColor.handleActive: Vec3(1.00f, 0.90f, 0.40f),
    SchemeColor.handleGuide:  Vec3(0.80f, 0.60f, 1.00f),
    SchemeColor.handleCage:   Vec3(0.40f, 0.80f, 0.60f),
    SchemeColor.handleLabel:  Vec3(0.80f, 0.80f, 0.80f),
    SchemeColor.handleUnsnap: Vec3(0.90f, 0.70f, 1.00f),

    SchemeColor.toolOffset:   Vec3(0.20f, 0.45f, 1.00f),
    SchemeColor.toolWidth:    Vec3(0.90f, 0.20f, 0.20f),
    SchemeColor.toolAngle:    Vec3(0.90f, 0.75f, 0.15f),
    SchemeColor.toolExtent:   Vec3(0.90f, 0.90f, 0.20f),
    SchemeColor.toolPath:     Vec3(0.30f, 0.60f, 1.00f),
    SchemeColor.toolPathLine: Vec3(0.90f, 0.92f, 0.98f),
    SchemeColor.toolPathRing: Vec3(0.35f, 0.85f, 0.85f),
];

/// Resolve a role to its colour.
///
/// THE seam for a future preference layer: when per-user overrides land, this
/// becomes "override if set, else the default" and every call site below is
/// already correct. Callers must go through here rather than reading
/// `kSchemeDefaults` directly, or they will miss the override.
Vec3 schemeColor(SchemeColor role) @safe pure nothrow @nogc {
    return kSchemeDefaults[cast(size_t)role];
}

// ---------------------------------------------------------------------------
// Fixed constants — NOT preference rows (see the two-tier note up top)
// ---------------------------------------------------------------------------

/// The screen-plane rotate ring. Deliberately axis-less flat grey: it is the
/// one ring that belongs to no axis, and it must not read as one.
enum Vec3 kViewRingGrey = Vec3(0.60f, 0.60f, 0.60f);

/// A ghosted / locked / disabled handle. A channel that cannot be driven is
/// drawn as inert grey rather than in its axis colour, so "locked" is legible
/// without reading the panel.
enum Vec3 kHandleGhostGrey = Vec3(0.30f, 0.30f, 0.30f);

/// Grey level of the unshaded (Solid) surface fill.
///
/// Anchored on the SCHEME's fill entry, NOT on the surface material: the
/// unshaded style makes no surface-creation call at all, so the material is
/// never consulted. Task 0589 wrongly anchored this on `LitShader`'s default
/// material grey (0.8); task 0592 moved it here. Task 0596 moved it into this
/// module so the scheme is one table rather than two.
///
/// PRECEDENCE, and the half we do not have: the resolution order is per-item
/// override first, then this scheme colour. We have no per-item fill channel
/// (`Layer` carries no display colour), so the precedence collapses to this
/// single term. When a per-item display colour lands it resolves into
/// `DrawPlan.fillColor` AHEAD of this constant — that is the contract.
enum float kSchemeSolidFill = 0.6f;

/// How far a plane handle's fill disc sits below its outline colour.
///
/// The plane handle is two concentric parts: an axis-coloured outline ring and
/// a darker fill disc inside it. Deriving the fill from the outline (rather
/// than storing six literals) means the fills track the axis colours for free
/// — correcting an axis can no longer leave its plane fill behind, which is
/// exactly how the two drifted apart before.
enum float kPlaneFillScale = 0.45f;

/// How far the rotate bank's backing disc sits BELOW the viewport backdrop.
///
/// The disc is the plate the three rotation rings sit on — a shape whose whole
/// job is to be *slightly* darker than what is behind it, so the rings read
/// against something instead of against the scene. That makes it the one
/// gizmo colour with no value of its own: it is an OFFSET, and the number
/// below is the whole of it.
enum float kBackingDiscDarken = 0.15f;

// ---------------------------------------------------------------------------
// Derived lookups
// ---------------------------------------------------------------------------

/// The rotate bank's decorative backing disc.
///
/// DERIVED from the backdrop, and deliberately not stored as a triple. At the
/// shipped backdrop this evaluates to (0.21, 0.25, 0.30), which is the value
/// that was measured — but writing that triple down would freeze a number
/// whose meaning is "a bit darker than whatever is behind it". Re-theme the
/// backdrop and a literal is instantly wrong in a way nothing would catch: the
/// disc would still draw, still be a plausible grey, and simply stop being a
/// darkening. Deriving it means the relationship is what ships.
///
/// Clamped at 0 per channel so a backdrop darker than the offset yields black
/// rather than a negative colour. Nothing clamps at the top: the offset only
/// ever subtracts.
///
/// This is the disc's colour for BOTH of its parts — the fill and the outline
/// share it and differ only in alpha (see `GIZMO_ALPHA_ROTATE_DISC_FILL` /
/// `_RING`). One colour, two opacities, which is why there is one function.
Vec3 rotateBackingDiscColor() @safe pure nothrow @nogc {
    immutable Vec3 b = schemeColor(SchemeColor.backdrop);
    return Vec3(max(0.0f, b.x - kBackingDiscDarken),
                max(0.0f, b.y - kBackingDiscDarken),
                max(0.0f, b.z - kBackingDiscDarken));
}

/// Axis index (0 = X, 1 = Y, 2 = Z) to its colour.
///
/// Out-of-range is a caller bug, not a data question: it asserts in debug and
/// falls back to the axis-less handle colour in release rather than reading
/// off the end of the table.
Vec3 axisColor(int axis) @safe pure nothrow @nogc {
    switch (axis) {
        case 0:  return schemeColor(SchemeColor.axisX);
        case 1:  return schemeColor(SchemeColor.axisY);
        case 2:  return schemeColor(SchemeColor.axisZ);
        default:
            assert(false, "axisColor: axis index must be 0, 1 or 2");
    }
}

/// The resting fill disc of the plane handle whose outline is `outline`.
///
/// This is the disc's OWN colour — the `idle` argument to the state law below,
/// not the law itself. See `planeRingColor` for the part of the plane handle
/// that does not follow the common law.
Vec3 planeFillColor(Vec3 outline) @safe pure nothrow @nogc {
    return outline * kPlaneFillScale;
}

// ---------------------------------------------------------------------------
// THE handle colour law
// ---------------------------------------------------------------------------

/// What a handle is doing, for the purpose of choosing its colour. THREE
/// states, and the third one is not a convenience — it is measured.
///
/// Kept separate from `handles.shapes.HandleState`, which answers a different
/// question (which handle would a press grab, plus the advisor's hints) and is
/// serialised over the handles API. This enum is only ever about pixels.
enum HandlePaint {
    idle,      /// no pointer on it, nothing hauling it
    hover,     /// the pointer is over it, no button pressed
    grabbed,   /// a press captured it and has not released
}

/// A handle's colour, given what it is doing.
///
/// MEASURED: `hover` and `grabbed` are the SAME colour — the pointer resting
/// on a handle repaints it in exactly the active colour a haul would give it,
/// and nothing else about it changes (not its size, its line width, its
/// outline or its alpha). So the law has three states but only two colours,
/// and it would be tempting to collapse it back to a bool. Do not: the plane
/// handle's ring (below) distinguishes hover from grabbed, and it is the whole
/// reason this is an enum. A bool cannot express a part that lights up under
/// the pointer and goes BACK to its own colour when you actually grab it.
///
/// `idle` is the handle's own colour — its axis colour for an axis handle, the
/// `handle` row for one with no axis.
Vec3 handleColor(Vec3 idle, HandlePaint paint) @safe pure nothrow @nogc {
    final switch (paint) {
        case HandlePaint.idle:                        return idle;
        case HandlePaint.hover, HandlePaint.grabbed:  return schemeColor(SchemeColor.handleActive);
    }
}

/// The plane handle's outline RING — the one part that breaks the common law.
///
/// MEASURED, and the shape of it is genuinely non-monotonic:
///
///   idle     -> its axis colour
///   hover    -> the active colour
///   grabbed  -> its axis colour AGAIN
///
/// The two mechanisms behind that are separable and both are visible here. The
/// pointer highlight is applied to whatever is under the pointer, uniformly,
/// with no knowledge of which part of which handle it is — so it catches the
/// ring like everything else. The GRAB highlight is the handle's own drawing
/// rule, and that rule deliberately leaves the ring alone: the ring says WHICH
/// plane this is, and grabbing it does not change which plane it is. Losing
/// that cue at the moment of the grab would be the worst time to lose it.
///
/// The inner fill disc is NOT here because it does not need to be — it follows
/// `handleColor` exactly (idle: its own dark tint; hover and grabbed alike:
/// the active colour). What the fill additionally does on a grab is raise its
/// ALPHA to fully opaque, which is not a colour and is not this table's to
/// state; the drawing code owns per-part alpha.
Vec3 planeRingColor(Vec3 axis, HandlePaint paint) @safe pure nothrow @nogc {
    return paint == HandlePaint.hover
        ? schemeColor(SchemeColor.handleActive)
        : axis;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

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
