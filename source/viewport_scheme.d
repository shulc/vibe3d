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
    handleActive,  /// the GRABBED handle. There is no separate hover colour — see handleColor()
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

// ---------------------------------------------------------------------------
// Derived lookups
// ---------------------------------------------------------------------------

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

/// The fill disc of the plane handle whose outline is `outline`.
Vec3 planeFillColor(Vec3 outline) @safe pure nothrow @nogc {
    return outline * kPlaneFillScale;
}

/// THE handle colour law: a handle is either idle or ENGAGED. Two states.
///
/// `engaged` means GRABBED — armed when the press captures the handle, cleared
/// on release. It is emphatically NOT hover: there is no pre-press rollover
/// colour in this scheme, and a handle that recolours under the bare pointer
/// is telling the user it did something it did not do. The arbiter drives this
/// bit from its capture, never from its hit test (`handles/arbiter.d`).
///
/// `idle` is the handle's own colour — its axis colour for an axis handle, the
/// `handle` row for one with no axis.
Vec3 handleColor(Vec3 idle, bool engaged) @safe pure nothrow @nogc {
    return engaged ? schemeColor(SchemeColor.handleActive) : idle;
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

/// The two colours a handle is allowed to be, and the one it is not.
unittest {
    const idle = schemeColor(SchemeColor.axisX);

    // Idle keeps its own colour...
    assert(handleColor(idle, false) == idle);
    // ...engaged takes the active colour, whatever the handle's own colour is.
    assert(handleColor(idle, true)  == schemeColor(SchemeColor.handleActive));
    assert(handleColor(schemeColor(SchemeColor.handle), true)
           == schemeColor(SchemeColor.handleActive));

    // The engaged colour is NOT the mesh-selection colour. We used to paint a
    // "selected" handle with the selection orange; that orange belongs to
    // selected geometry and never to a handle, and the two must stay distinct
    // or the gizmo starts speaking the mesh's language.
    assert(schemeColor(SchemeColor.handleActive) != schemeColor(SchemeColor.selection));

    // ...nor the old hover yellow, which stood for a state that does not exist.
    immutable Vec3 retiredRolloverYellow = Vec3(1.0f, 0.95f, 0.15f);
    immutable Vec3 retiredSelectedOrange = Vec3(1.0f, 0.64f, 0.0f);
    assert(schemeColor(SchemeColor.handleActive) != retiredRolloverYellow);
    assert(schemeColor(SchemeColor.handleActive) != retiredSelectedOrange);
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

/// The fixed constants are fixed.
unittest {
    assert(kViewRingGrey    == Vec3(0.6f, 0.6f, 0.6f));
    assert(kHandleGhostGrey == Vec3(0.3f, 0.3f, 0.3f));
    // The view ring must not be mistakable for an axis: it belongs to none.
    foreach (ax; 0 .. 3)
        assert(kViewRingGrey != axisColor(ax));
}
