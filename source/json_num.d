// ---------------------------------------------------------------------------
// json_num — print one number into a hand-assembled JSON body, or `null`.
//
// WHY THIS EXISTS. Every JSON body in this tree is built by string
// concatenation, and `format("%f", x)` on a non-finite float prints the bare
// tokens `inf` / `-inf` / `nan` / `-nan`. Those are not JSON. One infinite
// coordinate anywhere in the mesh therefore made `/api/model` UNPARSEABLE for
// every client at once — the suite, the perf harness, any external tool —
// which is task 1550's measured defect (found by the fuzz registry, 1412, with
// 47 witnesses).
//
// WHY `null` AND NOT `0`. `0` would make the body parse and the geometry read
// as plausible-but-wrong: the response would lie about where the vertex is.
// `null` parses, is NOT a coordinate, and trips a strict consumer's
// `.floating` — so the failure stays visible on the reader's side too. A
// string `"inf"` was rejected because it changes the value's TYPE (schema
// error instead of data error, which invites "handling" it), and HTTP 500 was
// rejected because it removes the one diagnostic view of a mesh exactly when
// the mesh is broken.
//
// WHY `spec` HAS NO DEFAULT. A `string spec = "%f"` default would compile at
// every one of the 24 call sites and silently reprint them all at `%f`. The
// sharpest victim would be `view.orientationToJson`'s nine `%.9g`, whose own
// doc comment (source/view.d) explains that nine significant digits IS the
// round-trip precision of a 32-bit float and that losing them tilts the
// horizon a little on every save and load. A mandatory parameter makes that
// erasure a compile error rather than a review-attention problem.
//
// WHY `double` AND NOT `float`. Measured before adopting it: over 200 000
// random floats plus the edge cases (±0, 0.1f, 1e-45f, float.max), formatting
// the float and formatting its double promotion gave ZERO differences for
// `%f`, `%.6f` and `%.9g`. Taking `double` lets one helper serve both without
// a template.
//
// WHAT THIS DOES NOT DO. It does not count, does not remember, and does not
// signal. The `"nonFinite"` block of `/api/model` is assembled by the call
// site (http_json.meshToJsonDetailed) from its own `isFinite` tests, so this
// module stays a pure function of its two arguments and carries no state.
// ---------------------------------------------------------------------------
module json_num;

import std.format : format;
import std.math   : isFinite;

/// Format `v` with `spec` when it is finite; otherwise emit the JSON literal
/// `null`. `spec` is mandatory — see the module header.
string jsonNum(double v, string spec) {
    return isFinite(v) ? format(spec, v) : "null";
}

// The canary of the emitter-scan gate (tests/unit/json_emitter_scan_test.d).
//
// It lives HERE, in a file the gate actually reads, and not in the test: a
// canary fed straight to the matcher proves only that the matcher matches,
// which is what the previous shape of that gate did. Read from a real file it
// exercises the whole path — open, mask comments, keep string literals, match
// — so a gate that has stopped reading the tree goes red instead of quietly
// reporting a clean one. The gate derives this line NUMBER by reading the file,
// so moving the line is harmless; deleting it is mutation M9.
version (unittest) private enum jsonNumScannerCanary = `{"canary":%f}`;

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
