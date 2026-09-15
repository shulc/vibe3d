module tests.unit.pie_key_release_law_test;

import pie_state : PieKeyUp, pieKeyUpEffect;

unittest { // U2a: taps through the exact 100 ms boundary stay open
    assert(pieKeyUpEffect(1000, 1000) == PieKeyUp.stay);
    assert(pieKeyUpEffect(1000, 1012) == PieKeyUp.stay);
    assert(pieKeyUpEffect(1000, 1100) == PieKeyUp.stay,
        "U2a exact 100 ms release must stay open");
}

unittest { // U2b: the first later millisecond closes and runs
    assert(pieKeyUpEffect(1000, 1101) == PieKeyUp.closeAndRun,
        "U2b 101 ms release must close and run");
}

unittest { // U2c: mixed timestamp domains conservatively count as a tap
    assert(pieKeyUpEffect(1000, 900) == PieKeyUp.stay,
        "U2c negative elapsed time must stay open");
}

unittest { // U2d: the owner-verified held release runs the hovered item
    assert(pieKeyUpEffect(1000, 1300) == PieKeyUp.closeAndRun,
        "U2d held release must close and run");
}
