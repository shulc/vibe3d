// Module unittests for `coord_rounding`, moved verbatim out of source/coord_rounding.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.coord_rounding_test;


import coord_rounding;

unittest {  // every enum value round-trips through its wire name
    foreach (m; [CoordinateRounding.None,   CoordinateRounding.Normal,
                 CoordinateRounding.Fine,   CoordinateRounding.Fixed,
                 CoordinateRounding.ForcedFixed]) {
        CoordinateRounding back = CoordinateRounding.ForcedFixed;
        assert(parseCoordRounding(coordRoundingName(m), back),
               "every mode's own wire name must parse back");
        assert(back == m);
    }
}

unittest {  // the wire values are the reference's, and the default is its own
    assert(cast(int)CoordinateRounding.None        == 0);
    assert(cast(int)CoordinateRounding.Normal      == 1);
    assert(cast(int)CoordinateRounding.Fine        == 2);
    assert(cast(int)CoordinateRounding.Fixed       == 3);
    assert(cast(int)CoordinateRounding.ForcedFixed == 4);
    // The default is rounding ON. A port whose default was `None` would ship
    // the measured term switched off; this assert is the thing that fails if
    // somebody "fixes" a test by moving the default.
    assert(kCoordRoundingDefault == CoordinateRounding.Fine);
    assert(kCoordRoundingDefault != CoordinateRounding.None);
}

unittest {  // an unrecognized name is REFUSED, not silently mapped to None
    CoordinateRounding m = CoordinateRounding.Fine;
    assert(!parseCoordRounding("",         m));
    assert(!parseCoordRounding("Fine",     m));   // case matters
    assert(!parseCoordRounding("forced",   m));
    assert(!parseCoordRounding("2",        m));
    assert(m == CoordinateRounding.Fine,
           "a rejected parse must not disturb the caller's value — a typo "
           ~ "that landed on None would switch the rounding off and look "
           ~ "like the term was never ported");
}

unittest {  // set / reset round-trip on the live value
    const saved      = coordRounding();
    const savedFixed = coordRoundingFixedIncrement();
    scope(exit) { setCoordRounding(saved); setCoordRoundingFixedIncrement(savedFixed); }

    setCoordRounding(CoordinateRounding.None);
    assert(coordRounding() == CoordinateRounding.None);
    setCoordRoundingFixedIncrement(0.25f);
    assert(coordRoundingFixedIncrement() == 0.25f);

    resetCoordRounding();
    assert(coordRounding() == kCoordRoundingDefault);
    assert(coordRoundingFixedIncrement() == kFixedIncrementDefault);
}
