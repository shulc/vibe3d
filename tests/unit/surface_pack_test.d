// `packSurfaceSlots` (S1d, model M6): the double-sided bit of every uploaded
// slot (`mat_flags[i].x`), the padding's (Surface.init: 0), and
// `anyTwoSided` over exactly the slots uploaded (a table entry at or past
// `LIT_MAX_MATS` is never uploaded, so it cannot raise it).
module tests.unit.surface_pack_test;

import std.format : format;

import mesh   : Surface;
import shader : packSurfaceSlots, LIT_MAX_MATS;

unittest {
    float[4 * LIT_MAX_MATS] base = -1, params = -1, flags = -1;
    assert(!packSurfaceSlots([], base, params, flags), "anyTwoSided must be false for an empty table");
    size_t slots;
    foreach (i; 0 .. LIT_MAX_MATS) {
        assert(flags[i * 4 .. i * 4 + 4] == [0f, 0, 0, 0],
            format("padding slot %d flags %s, expected Surface.init's single-sided 0", i, flags[i * 4 .. i * 4 + 4]));
        ++slots;
    }
    assert(slots == LIT_MAX_MATS && LIT_MAX_MATS == 64, format("padding floor: %d slots", slots));

    Surface one, two;
    two.twoSided = true;
    assert(packSurfaceSlots([one, two, one], base, params, flags),
        "anyTwoSided must be true with slot 1 double-sided");
    assert(flags[0] == 0 && flags[4] == 1 && flags[8] == 0 && flags[12] == 0,
        format("per-slot bits %s / %s / %s / pad %s, expected 0 / 1 / 0 / 0", flags[0], flags[4], flags[8], flags[12]));

    // The boundary: the last uploaded slot raises it; the first beyond does not.
    Surface[] at63 = new Surface[64];
    at63[63].twoSided = true;
    assert(packSurfaceSlots(at63, base, params, flags) && flags[63 * 4] == 1,
        "a double-sided slot 63 (the last uploaded) must raise anyTwoSided");
    Surface[] at64 = new Surface[65];
    at64[64].twoSided = true;
    assert(!packSurfaceSlots(at64, base, params, flags),
        "a double-sided entry 64 is never uploaded: anyTwoSided must stay false");
}
