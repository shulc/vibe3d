module pie_geometry;

// ---------------------------------------------------------------------------
// Pie-menu geometry — pure functions, no ImGui, no state (task 1800).
//
// A pie menu is `n` equal wedges around the point where it opened. Slot 0 is
// centred on TWELVE O'CLOCK and the rest follow CLOCKWISE, so a slot's centre
// angle is `i * 2π/n` measured from straight up, turning right.
//
// Why clockwise-from-noon and not something else: it is the only reading of
// the reference's shipped 8-item viewport pie (Top, Perspective, Right, Front,
// Bottom, Back, Left, Maximize) under which all four axis views land on their
// own compass point — Top north, Right east, Bottom south, Left west. Read
// anti-clockwise the same list puts "Right" in the west. That is a DEDUCTION
// from the shipped order, not a measurement of the drawn menu; the task card
// records it as such.
//
// Screen axes: `dy` grows DOWNWARD (SDL / ImGui convention), so "up" is a
// NEGATIVE dy. Every function here takes screen-space deltas and the sign is
// pinned by tests/unit/pie_geometry_test.d rather than by this comment.
// ---------------------------------------------------------------------------

import std.math : atan2, sqrt, PI, sin, cos, floor;

/// Radius (in pixels, from the centre) inside which no slot is selected.
/// A pie opened by a chord starts with the cursor exactly at the centre, so
/// the dead zone is what makes "opened but nothing chosen yet" a representable
/// state — and it is the same state a tap-and-release lands in.
enum float PIE_DEAD_ZONE_PX = 22.0f;

/// Which slot does the direction (`dx`, `dy`) from the pie centre select?
///
/// Returns `-1` when the cursor is inside `deadZonePx` of the centre (nothing
/// selected) or when `n <= 0`. Otherwise `0 .. n-1`, slot 0 centred straight
/// up and numbering clockwise.
int sectorAt(float dx, float dy, int n, float deadZonePx = PIE_DEAD_ZONE_PX) {
    if (n <= 0) return -1;

    immutable float r = sqrt(dx * dx + dy * dy);
    if (r <= deadZonePx) return -1;

    // Angle clockwise from straight up. Screen dy points down, so "up" is
    // -dy; atan2(dx, -dy) is 0 at noon, +π/2 at 3 o'clock (dx > 0), i.e.
    // already turning clockwise on screen.
    float a = atan2(dx, -dy);
    if (a < 0) a += 2 * PI;

    // Slot i owns [i*w - w/2, i*w + w/2); shifting by half a slot before the
    // divide puts the boundary, not the centre, on the integer edges.
    immutable float w = 2 * PI / n;
    int slot = cast(int) floor((a + w * 0.5f) / w);
    if (slot >= n) slot -= n;     // the wrap of the half-slot shift
    if (slot < 0)  slot += n;
    return slot;
}

/// Centre angle of slot `i`, clockwise radians from straight up.
float slotCenterAngle(int i, int n) {
    if (n <= 0) return 0.0f;
    return cast(float)(i * 2 * PI / n);
}

/// Unit direction of slot `i`'s centre in SCREEN space (y down), so a caller
/// can place a label at `centre + dir * radius` without redoing the sign.
void slotCenterDir(int i, int n, out float dx, out float dy) {
    immutable float a = slotCenterAngle(i, n);
    dx =  cast(float) sin(a);
    dy = -cast(float) cos(a);
}
