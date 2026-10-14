module pie_geometry;

// Eight fixed compass slots, box placement and angular hover; task/evidence: doc/tasks/work/6208-pie-menu-reference-parity.md.

import std.math : atan2, sqrt, PI, sin, cos, floor;

/// A pie always owns the eight compass slots, even when some are holes.
enum int PIE_SLOTS = 8;

struct PieBoxTL {
    int x;
    int y;
}

/// Top-left of one fixed slot, relative to the point where the pie opened.
PieBoxTL pieBoxTopLeft(int slot, int unitH, int boxW) {
    assert(slot >= 0 && slot < PIE_SLOTS);
    immutable int radius = 2 * unitH;
    immutable int neX = (radius / 2 - boxW / 2)
        > cast(int)floor(radius / 3.5)
        ? radius / 2 - boxW / 2
        : cast(int)floor(radius / 3.5);
    immutable int neY = cast(int)floor(-radius / 2.0 - 0.75 * unitH);
    immutable int seY = cast(int)floor(radius / 2 - unitH / 2
                                      + 0.25 * unitH);
    int swX = -radius / 2 - boxW / 2;
    if (swX + boxW > -radius / 3.5)
        swX = cast(int)floor(-radius / 3.5 - boxW);

    switch (slot) {
        case 0: return PieBoxTL(-boxW / 2, -radius - unitH);
        case 1: return PieBoxTL(neX, neY);
        case 2: return PieBoxTL(radius, -unitH / 2);
        case 3: return PieBoxTL(neX, seY);
        case 4: return PieBoxTL(-boxW / 2, radius);
        case 5: return PieBoxTL(swX, seY);
        case 6: return PieBoxTL(-radius - boxW, -unitH / 2);
        case 7: return PieBoxTL(swX, neY);
        default: assert(false);
    }
}

/// Fixed-slot angular hover. `live` suppresses holes and unavailable items.
int pieHoverAt(int dx, int dy, int unitH,
               const bool[PIE_SLOTS] live) {
    immutable double distance = sqrt(cast(double)dx * dx
                                   + cast(double)dy * dy);
    if (cast(int)distance < unitH) return -1;

    double angle = atan2(cast(double)dx, cast(double)-dy);
    if (angle < 0.0) angle += 2.0 * PI;
    immutable int slot = cast(int)floor((angle + PI / 8.0) / (PI / 4.0))
                             % PIE_SLOTS;
    if (slot < 0 || slot >= PIE_SLOTS) return -1;
    return live[slot] ? slot : -1;
}

/// Unit screen-space direction of a fixed compass slot, for the hub tick.
void pieSlotDir(int slot, out float ux, out float uy) {
    assert(slot >= 0 && slot < PIE_SLOTS);
    immutable double angle = slot * PI / 4.0;
    ux = cast(float)sin(angle);
    uy = -cast(float)cos(angle);
}
