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
import std.algorithm.comparison : max, min;

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
    preHighlight,  /// the thing under the pointer, before any click commits to it
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
    SchemeColor.preHighlight: Vec3(0.549f, 0.710f, 0.780f),

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
/// The disc has ONE part, so this is simply its colour — drawn at it, opaque
/// (`GIZMO_ALPHA_ROTATE_DISC`), with nothing else sharing it.
///
/// It used to be described here as one colour serving two parts at two
/// opacities, a plate under an outline. Task 0610 measured the shape and there
/// is no plate; the wording is corrected rather than deleted because the
/// derivation below is the half of that row which survived, and survived
/// exactly — the drawn ink matches this expression to the last 8-bit level over
/// two different backdrops.
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
// THE item colour law
// ---------------------------------------------------------------------------

/// How far the hovered-AND-selected shade sits ABOVE the selection colour.
///
/// MEASURED, and measured as an OFFSET rather than as a third colour: the
/// capture drove the selection colour onto two different values and read the
/// hovered-selected paint back both times, and both landed on
/// `selection + 0.1` per channel to within one 8-bit step. A 50% blend toward
/// the pre-highlight colour and an additive 13% of the pre-highlight colour
/// were both refuted by the second base colour — on a red selection they
/// predict a blue-tinted result and the paint measured a pure brighten.
///
/// This is why `itemHighlightColor` derives instead of storing (255, 194, 66):
/// a stored triple is instantly wrong the moment the selection colour is
/// re-themed, and wrong in the way nothing catches — it would still draw, still
/// be a plausible orange, and simply stop being "the selected item, lit".
enum float kItemHoverBrighten = 0.1f;

/// What an ITEM is doing, for the purpose of choosing the colour its wireframe
/// is painted in while the current selection type is Item.
///
/// FOUR states, and the fourth is not a convenience: hovering an item that is
/// already selected is its own paint, measurably different from both of the
/// states it sits between. A law with three states could only make it agree
/// with `selected` (losing the hover cue exactly where the user is about to
/// click) or with `hovered` (losing the selection cue), and both were measured
/// false.
///
/// `none` is a real member rather than a null colour: most items in a document
/// are neither, and a caller has to be able to say so without inventing a
/// sentinel colour that a paint pass could accidentally draw.
enum ItemHighlight {
    none,             /// neither selected nor under the pointer — not painted
    hovered,          /// under the pointer, not selected
    selected,         /// selected, pointer elsewhere
    selectedHovered,  /// selected AND under the pointer
}

/// The state of an item, from the two booleans that decide it.
///
/// Trivial, and a function anyway — the two call sites (the draw pass and its
/// test) must not each write their own `?:` chain, which is how a "hovered and
/// selected paints as merely selected" bug gets into one of them alone.
ItemHighlight itemHighlight(bool selected, bool hovered) @safe pure nothrow @nogc {
    if (selected) return hovered ? ItemHighlight.selectedHovered : ItemHighlight.selected;
    return hovered ? ItemHighlight.hovered : ItemHighlight.none;
}

/// An item's highlight colour, given what it is doing.
///
/// MEASURED (task 0647). Two rows are scheme lookups and the third is derived:
///
///   hovered          -> the GENERIC pre-highlight colour. Established by a
///                       preference lever, not by matching a number against a
///                       table: each candidate scheme colour was driven onto
///                       its own RGB axis and the capture re-run, and the paint
///                       followed the generic pre-highlight row. The
///                       FACE-specific pre-highlight (our light blue face tint)
///                       was driven to magenta and never appeared, so the two
///                       must not be collapsed into one row however close they
///                       look.
///   selected         -> the selection colour, unchanged.
///   selectedHovered  -> `clamp(selection + kItemHoverBrighten, 0, 1)`.
///
/// `none` is a caller bug, not a fourth colour: an item that is neither
/// selected nor hovered is not painted at all, and a function that answered
/// some colour for it would let a pass draw over every item in the document.
Vec3 itemHighlightColor(ItemHighlight h) @safe pure nothrow @nogc {
    final switch (h) {
        case ItemHighlight.none:
            assert(false, "itemHighlightColor: `none` is not painted — the "
                          ~ "caller must skip it, not ask for its colour");
        case ItemHighlight.hovered:
            return schemeColor(SchemeColor.preHighlight);
        case ItemHighlight.selected:
            return schemeColor(SchemeColor.selection);
        case ItemHighlight.selectedHovered:
            immutable Vec3 s = schemeColor(SchemeColor.selection);
            return Vec3(min(1.0f, max(0.0f, s.x + kItemHoverBrighten)),
                        min(1.0f, max(0.0f, s.y + kItemHoverBrighten)),
                        min(1.0f, max(0.0f, s.z + kItemHoverBrighten)));
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
