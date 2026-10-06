module tests.unit.haul_axis_latch_test;

import tools.edit.haul_axis_latch : HaulAxisLatch, HaulAxis;
import std.file : readText;
import std.string : indexOf;
import std.algorithm : count;
import tests.unit.census_symbols : blankNonCode, blankUnittestBodies;

unittest {
    foreach (first; [1, 2]) {
        HaulAxisLatch latch;
        latch.begin(true);
        assert(!latch.allows(HaulAxis.horizontal) && !latch.allows(HaulAxis.vertical),
            "pressed lock waits for delivered motion");
        latch.motion(first, 0);
        assert(latch.allows(HaulAxis.horizontal), "first nonzero elects horizontal");
        assert(!latch.allows(HaulAxis.vertical), "horizontal excludes vertical");
        latch.motion(first, -40);
        assert(latch.axis == HaulAxis.horizontal, "later vertical cannot re-elect");
    }
}

unittest {
    HaulAxisLatch latch;
    latch.begin(true);
    latch.motion(0, 0);
    assert(latch.axis == HaulAxis.undecided, "zero event cannot elect a channel");
    latch.motion(-1, 0);
    assert(latch.axis == HaulAxis.horizontal, "first nonzero after zero elects horizontal");
    latch.begin(true);
    latch.motion(0, -1);
    assert(latch.axis == HaulAxis.vertical, "vertical-only first event elects vertical");
}

unittest {
    foreach (dx; [-3, 3]) foreach (dy; [-3, 3]) {
        HaulAxisLatch latch;
        latch.begin(true);
        latch.motion(dx, dy);
        assert(latch.axis == HaulAxis.vertical, "equal magnitudes elect vertical");
        assert(!latch.allows(HaulAxis.horizontal), "vertical excludes horizontal");
        assert(latch.allows(HaulAxis.vertical), "vertical channel remains enabled");
    }
}

unittest {
    HaulAxisLatch latch;
    latch.begin(true);
    latch.motion(1, 0);
    latch.begin(true);
    assert(latch.axis == HaulAxis.undecided, "new press resets election");
    latch.motion(0, 1);
    assert(latch.axis == HaulAxis.vertical, "new press elects independently");
    latch.begin(false);
    latch.motion(10, 40);
    assert(latch.axis == HaulAxis.undecided, "ordinary press does not elect");
    assert(latch.allows(HaulAxis.horizontal) && latch.allows(HaulAxis.vertical),
        "ordinary press permits both channels");
}

unittest {
    enum consumers = ["source/tools/edit/poly_bevel.d", "source/tools/edit/edge_extrude.d"];
    assert(consumers.length == 2, "free-haul consumer population");
    foreach (path; consumers) {
        const code = blankUnittestBodies(blankNonCode(readText(path)));
        assert(code.count("freeHaul.begin((mods & KMOD_CTRL) != 0);") == 1,
            path ~ " press policy uses captured Ctrl");
        assert(code.count("freeHaul.motion(dx, dy);") == 1,
            path ~ " motion elects through shared latch");
        assert(code.count("freeHaul.allows(HaulAxis.vertical)") == 1 &&
            code.count("freeHaul.allows(HaulAxis.horizontal)") == 1,
            path ~ " both channel writes use shared latch");
        const start = code.indexOf("override bool onMouseMotion");
        const end = code.indexOf("override", start + 10);
        assert(start >= 0 && end > start, path ~ " motion source population");
        assert(code[start .. end].count("SDL_GetModState") == 0,
            path ~ " motion does not reread modifier");
    }
}
