// Module unittests for `pie_geometry` — the direction→wedge law of the pie
// menu (task 1800).
//
// The law under test: slot 0 is centred on TWELVE O'CLOCK and numbering runs
// CLOCKWISE, on screen axes (y grows down). Everything else in the feature —
// which wedge lights up, which one a release fires, where a label is drawn —
// is downstream of this one function, so this is where the compass is pinned.
//
// Note the cases are NOT all on the axes. Axis-only cases pass under a mapping
// rotated by half a slot as well (the axis sits inside the wedge either way);
// the pairs straddling a boundary are the ones that can tell the two apart.
module tests.unit.pie_geometry_test;

import std.math : PI, sin, cos;

import pie_geometry;

// A point `deg` degrees clockwise from noon, at radius `r`.
private void dirAt(float deg, float r, out float dx, out float dy) {
    immutable float a = cast(float)(deg * PI / 180.0);
    dx =  cast(float)(sin(a) * r);
    dy = -cast(float)(cos(a) * r);   // screen y grows DOWN, so noon is -y
}

private int slotAtDeg(float deg, int n, float r = 90.0f) {
    float dx, dy;
    dirAt(deg, r, dx, dy);
    return sectorAt(dx, dy, n);
}

unittest {  // eight wedges: the compass, read clockwise from noon
    assert(sectorAt(  0, -90, 8) == 0, "up = slot 0");
    assert(sectorAt( 64, -64, 8) == 1, "up-right = slot 1");
    assert(sectorAt( 90,   0, 8) == 2, "right = slot 2");
    assert(sectorAt( 64,  64, 8) == 3, "down-right = slot 3");
    assert(sectorAt(  0,  90, 8) == 4, "down = slot 4");
    assert(sectorAt(-64,  64, 8) == 5, "down-left = slot 5");
    assert(sectorAt(-90,   0, 8) == 6, "left = slot 6");
    assert(sectorAt(-64, -64, 8) == 7, "up-left = slot 7");
}

unittest {  // the boundaries, which is what separates this law from a rotated one
    // With 8 wedges the seam between slot 0 and slot 1 sits at 22.5°.
    assert(slotAtDeg(21.0f, 8) == 0, "just before the seam is still slot 0");
    assert(slotAtDeg(24.0f, 8) == 1, "just past the seam is slot 1");
    // ...and the seam between the last slot and slot 0, i.e. the wrap at 337.5°.
    assert(slotAtDeg(336.0f, 8) == 7);
    assert(slotAtDeg(339.0f, 8) == 0);
    // Dead-on noon and dead-on the wrap point both resolve, no gap.
    assert(slotAtDeg(0.0f,   8) == 0);
    assert(slotAtDeg(359.9f, 8) == 0);
}

unittest {  // fewer than eight items: the circle is divided evenly, still from noon
    assert(slotAtDeg(  0.0f, 4) == 0);
    assert(slotAtDeg( 90.0f, 4) == 1);
    assert(slotAtDeg(180.0f, 4) == 2);
    assert(slotAtDeg(270.0f, 4) == 3);
    // A quarter-wedge spans ±45°, so 44° is still slot 0 and 46° is slot 1.
    assert(slotAtDeg(44.0f, 4) == 0);
    assert(slotAtDeg(46.0f, 4) == 1);

    // Three wedges: 120° each, seams at 60° / 180° / 300°.
    assert(slotAtDeg( 59.0f, 3) == 0);
    assert(slotAtDeg( 61.0f, 3) == 1);
    assert(slotAtDeg(179.0f, 3) == 1);
    assert(slotAtDeg(181.0f, 3) == 2);

    // One wedge owns the whole circle.
    assert(slotAtDeg(  0.0f, 1) == 0);
    assert(slotAtDeg(200.0f, 1) == 0);
}

unittest {  // the dead zone — "open but aimed at nothing" must be representable
    assert(sectorAt(0, 0, 8) == -1, "dead centre selects nothing");
    assert(sectorAt(0, -(PIE_DEAD_ZONE_PX - 2.0f), 8) == -1,
           "inside the dead radius selects nothing, whatever the direction");
    assert(sectorAt(0, -(PIE_DEAD_ZONE_PX + 2.0f), 8) == 0,
           "just outside it, the direction counts again");
    // This is the state a chord TAP lands in, and app.d's key-release branch
    // keys the ring's "stay open" behaviour off exactly this -1.
    assert(sectorAt(PIE_DEAD_ZONE_PX * 0.5f, PIE_DEAD_ZONE_PX * 0.5f, 8) == -1);
}

unittest {  // degenerate inputs answer "nothing", never an out-of-range slot
    assert(sectorAt(0, -90, 0) == -1);
    assert(sectorAt(0, -90, -3) == -1);
    // Every direction of a full turn lands inside range for every size we draw.
    foreach (n; 1 .. 9)
        for (float deg = 0; deg < 360.0f; deg += 3.0f) {
            immutable int s = slotAtDeg(deg, n);
            assert(s >= 0 && s < n, "slot must be in range");
        }
}

unittest {  // slotCenterDir agrees with sectorAt — a label cannot sit in a
            // different wedge from the one it names
    foreach (n; [3, 4, 5, 8]) {
        foreach (i; 0 .. n) {
            float dx, dy;
            slotCenterDir(i, n, dx, dy);
            assert(sectorAt(dx * 90.0f, dy * 90.0f, n) == i,
                   "the centre direction of slot i must resolve back to slot i");
        }
    }
}
