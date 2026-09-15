module tests.unit.pie_layout_law_test;

import pie_geometry : PIE_SLOTS, pieBoxTopLeft, pieHoverAt, pieSlotDir;
import std.file : readText;
import std.json : JSONValue, parseJSON;
import std.math : PI, cos, lround, sin;

private JSONValue fixture() {
    return parseJSON(readText("tests/fixtures/pie_menu_layout.json"));
}

private int iv(JSONValue value) {
    return cast(int)value.integer;
}

unittest { // U1a: every captured text-box placement
    auto root = fixture();
    size_t checked;
    size_t[5] bySheet;
    foreach (i, sheet; root["instances"].array) {
        immutable int h = iv(sheet["H"]);
        immutable int r = iv(sheet["R"]);
        immutable int w = iv(sheet["W"]);
        assert(r == 2 * h, "U1a fixture radius must be twice H");
        foreach (box; sheet["boxes"].array) {
            immutable int slot = iv(box["slot"]);
            auto got = pieBoxTopLeft(slot, h, w);
            assert(got.x == iv(box["x"]) && got.y == iv(box["y"]),
                "U1a captured pie box placement differs");
            assert(iv(box["w"]) == w && iv(box["h"]) == h,
                "U1a captured box dimensions differ from its sheet");
            ++checked;
            ++bySheet[i];
        }
    }
    assert(checked == 35 && bySheet == [8, 8, 6, 5, 8],
        "U1a pie-box fixture population changed");
}

unittest { // U1b: the complete captured hover sweep
    auto hover = fixture()["hover"];
    immutable int h = iv(hover["H"]);
    bool[PIE_SLOTS] live = true;
    size_t checked;
    foreach (probe; hover["probes"].array) {
        assert(pieHoverAt(iv(probe["dx"]), iv(probe["dy"]), h, live)
               == iv(probe["hover"]),
            "U1b captured angular hover differs");
        ++checked;
    }
    assert(checked == 71, "U1b hover fixture population changed");
}

unittest { // U1c: exact integer edge of the dead zone
    bool[PIE_SLOTS] live = true;
    foreach (h; [24, 32]) {
        assert(pieHoverAt(0, -(h - 1), h, live) == -1,
            "U1c point inside H must remain idle");
        assert(pieHoverAt(0, -h, h, live) == 0,
            "U1c exact H boundary must select north");
    }
}

unittest { // U1d: fixed holes do not cause the remaining slots to re-space
    bool[PIE_SLOTS] live = true;
    live[7] = false;
    assert(pieHoverAt(-56, -56, 32, live) == -1,
        "U1d NW hole must suppress nearby hover");
    assert(pieHoverAt(-800, -800, 32, live) == -1,
        "U1d NW hole must suppress unbounded hover");
    assert(pieHoverAt(-80, 0, 32, live) == 6,
        "U1d west remains fixed at slot 6");
}

unittest { // U1e: hover follows angle even inside a wide neighbouring box
    auto p = fixture()["wideBoxProbe"];
    bool[PIE_SLOTS] live = true;
    assert(pieHoverAt(iv(p["dx"]), iv(p["dy"]), iv(p["H"]), live)
           == iv(p["hover"]),
        "U1e wide-box probe must select by angle");
}

unittest { // U1f: negative SW placement uses floor, not truncation
    assert(pieBoxTopLeft(5, 24, 79).x == -93,
        "U1f SW placement must floor the negative pull-in");
}

unittest { // U1g: the clockwise seam wraps to north without an array fault
    bool[PIE_SLOTS] live = true;
    int hoverAt(double degrees) {
        immutable double angle = degrees * PI / 180.0;
        enum double radius = 100_000.0;
        return pieHoverAt(cast(int)lround(sin(angle) * radius),
                          cast(int)lround(-cos(angle) * radius), 32, live);
    }
    assert(hoverAt(336.0) == 7,
        "U1g 336-degree probe must remain in the NW slot");
    assert(hoverAt(339.0) == 0,
        "U1g 339-degree probe must wrap to the north slot");
    assert(hoverAt(359.9) == 0,
        "U1g 359.9-degree probe must wrap to the north slot");
}

unittest { // U1h: SE uses integer H/2 before the quarter-H adjustment
    assert(pieBoxTopLeft(3, 5, 17).y == 4,
        "U1h H congruent to 1 mod 4 must use integer half-height");
}

unittest { // U1i: every tick direction round-trips through angular hover
    bool[PIE_SLOTS] live = true;
    size_t checked;
    foreach (slot; 0 .. PIE_SLOTS) {
        float ux, uy;
        pieSlotDir(slot, ux, uy);
        assert(pieHoverAt(cast(int)(ux * 90), cast(int)(uy * 90), 24, live)
               == slot,
            "U1i pie slot direction does not round-trip through hover");
        ++checked;
    }
    assert(checked == 8, "U1i pie slot-direction population changed");
}
