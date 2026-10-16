module vibe3d.util.json_number.tests.unit.json_num_test;

import vibe3d.util.json_number.json_num : jsonNum;

unittest {
    // Finite values pass through the specifier untouched — the whole point of
    // making `spec` mandatory is that this text is the call site's, not ours.
    assert(jsonNum(1.0, "%f") == "1.000000");
    assert(jsonNum(-0.5, "%f") == "-0.500000");
    assert(jsonNum(1.0, "%.6f") == "1.000000");
    assert(jsonNum(0.5, "%.3f") == "0.500");
    assert(jsonNum(1.0, "%.9g") == "1");
    assert(jsonNum(0.0, "%.9g") == "0");
}

unittest {
    // Every non-finite shape becomes `null`, whatever the specifier.
    immutable double inf = double.infinity;
    assert(jsonNum(inf, "%f") == "null");
    assert(jsonNum(-inf, "%f") == "null");
    assert(jsonNum(double.nan, "%f") == "null");
    assert(jsonNum(-double.nan, "%f") == "null");
    assert(jsonNum(inf, "%.6f") == "null");
    assert(jsonNum(-inf, "%.9g") == "null");
    assert(jsonNum(double.nan, "%.9g") == "null");

    // The float promotions the real call sites hand us behave identically.
    // `1e39` narrowed to `float` IS infinity, which is exactly how the defect
    // arrives over the wire (`params._jsonFloat` does `cast(float)
    // v.floating`).
    //
    // The narrowing goes through a RUNTIME variable on purpose. Measured on
    // dmd here: `cast(float)1e39` folds at compile time while KEEPING the
    // literal at `real` precision, so `writeln(cast(float)1e39)` prints `inf`
    // and `isInfinity` is true, yet `cast(double)(cast(float)1e39)` — which is
    // what passing it to this function's `double` parameter does — comes back
    // as a finite `1e+39`. Written as a constant expression, this assertion
    // would be testing the constant folder, not the defect.
    double wide = 1e39;
    float  narrowed = cast(float) wide;
    assert(jsonNum(narrowed, "%f") == "null");

    float negInf = -float.infinity;
    float fnan   = float.nan;
    assert(jsonNum(negInf, "%f") == "null");
    assert(jsonNum(fnan, "%f") == "null");
}

unittest {
    // `null` is what a JSON parser must see — assert against the parser, not
    // against the spelling, because the spelling is only interesting insofar
    // as std.json accepts it.
    import std.json : parseJSON, JSONType;
    auto v = parseJSON("[" ~ jsonNum(double.infinity, "%f") ~ ","
                           ~ jsonNum(2.5, "%f") ~ "]");
    assert(v.array.length == 2);
    assert(v.array[0].type == JSONType.null_);
    assert(v.array[1].floating == 2.5);
}
