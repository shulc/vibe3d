// param_cast_overflow_test.d — the behavioural replacement for the UBSan
// phase of task 1410.
//
// WHY THIS EXISTS INSTEAD OF A SANITIZER
// -------------------------------------
// The plan's cheapest phase was `--fsanitize=undefined`, whose named first
// hit was `source/params.d:809` — `int iv = cast(int)_jsonFloat(*jp);`, where
// a JSON `1e39` becomes `float.infinity` and the cast to `int` is undefined
// behaviour. That phase has NO MECHANISM on this toolchain: measured on the
// shipped LDC 1.42.0, `--fsanitize=` accepts address/thread/memory/leak/fuzzer
// and rejects `undefined`, `integer`, `bounds` and `float-cast-overflow`
// outright ("Error: Unrecognized -fsanitize value 'undefined'"). There is no
// UBSan runtime in the tarball.
//
// The defect survives the loss of its oracle, so the oracle is replaced rather
// than the defect forgiven: this asks the question BEHAVIOURALLY. A parameter
// that declares `[min,max]` must not be reachable outside `[min,max]` from the
// wire, whatever the cast does on the way.
//
// WHAT WAS ACTUALLY MEASURED (and what was NOT)
// ---------------------------------------------
// Two claims were checked here directly on LDC 1.42.0 before this test was
// written, because one of them turned out to be false:
//
//   * TRUE — `cast(int)` of inf / -inf / NaN / 3e9f yields int.min
//     (-2147483648) at -O0.
//   * TRUE — with those values as COMPILE-TIME CONSTANTS, -O2 folds all four
//     to one arbitrary garbage constant instead (4898104 in one build; the
//     value is address-dependent and not stable across builds). That is UB
//     manifesting as a release-only answer.
//   * FALSE, as a description of THIS code path — params.d's float is a
//     RUNTIME value out of a JSON document, so the optimiser has nothing to
//     fold. Measured with a value that cannot be constant-propagated:
//     -O0 and -O2 -release BOTH produce -2147483648, for inf, -inf, NaN and
//     3e9 alike. So the debug build and the shipped release agree here, and
//     the "release misbehaves differently from any debug build" framing does
//     not apply to params.d:809 as written.
//
// What remains, and is the whole content of this test: int.min is garbage
// either way, and whether it reaches the kernel depends ENTIRELY on
// `enforceBounds_`. The clamp at params.d:810-813 is gated on that flag, so a
// param that declares bounds without opting in gets the raw int.min. Two live
// sites did exactly that when this test was written (see below).
//
// LIVE FINDING THIS TEST WAS BORN RED ON
// --------------------------------------
// Driven over real HTTP against an ordinary build:
//     tool.attr mesh.loopSliceTool length 1e39  →  read back -2147483648
//     tool.attr pen currentPoint 1e39           →  read back -2147483648
// Both declare bounds in the registry (`[20,2000]` and `[-1,1024]`) and
// neither carried `.enforceBounds()`. `loopSliceTool.length` feeds
// `length_px()`, i.e. screen-space slider geometry; `pen.currentPoint` has a
// hand-written clamp in `onParamChanged` that the `tool.attr` path does not
// reach. Both were given `.enforceBounds()` as part of task 1410 — the
// two-layer contract of doc/param_bounds_plan.md (task 0365) applied to two
// stragglers, not a new policy.
//
// MUTATION (this test is not finished without it)
// -----------------------------------------------
// Remove `.enforceBounds()` from `source/tools/slice/loop_slice_tool.d:615`
// and this test fails with:
//   "Int param with declared bounds [20,2000] took the value -2147483648 from
//    JSON 1e39"
module tests.unit.param_cast_overflow_test;

import std.json   : JSONValue, parseJSON;
import std.format : format;
import params     : Param;

// ---------------------------------------------------------------------------
// The property, stated over the function itself. This is the whole of the
// wire path for a numeric param: /api/command and tool.attr both land in
// `injectParamsInto` (params.d:788) with a parsed JSONValue.
// ---------------------------------------------------------------------------
private void assertBoundedAfterInject(string what, int lo, int hi,
                                      string jsonLiteral)
{
    int storage = lo;
    auto p = Param.int_("probe", "Probe", &storage, lo)
                  .min(lo).max(hi).enforceBounds();
    auto pj = parseJSON(`{"probe":` ~ jsonLiteral ~ `}`);
    Param[] schema = [p];
    import params : injectParamsInto;
    injectParamsInto(schema, pj);
    assert(storage >= lo && storage <= hi,
        format("%s: %s injected into a [%d,%d] Int gave %d",
               what, jsonLiteral, lo, hi, storage));
}

unittest { // EnforcedIntSurvivesEveryWireExtreme
    // `1e39` is the reachable inf: `_jsonFloat` (params.d:927) narrows the
    // JSON double to `float`, and 1e39 overflows float's range. It is also
    // the LARGEST literal that gets this far — `1e999` makes std.json throw
    // `Range error` before any of our code runs (so it is an input-validation
    // question, not a clamp question, and is deliberately not probed here).
    // NaN is NOT reachable over the wire at all: bare `nan` in an argstring
    // parses as a STRING and `_jsonFloat` silently answers 0.0f, and the
    // argstring number grammar has no exponent. inf, -inf and plain int
    // overflow are the whole reachable extreme set.
    foreach (lit; ["1e39", "-1e39", "3000000000", "-3000000000",
                   "2147483648", "0", "-1"]) {
        assertBoundedAfterInject("enforced [20,2000]", 20, 2000, lit);
        assertBoundedAfterInject("enforced [-1,1024]", -1, 1024, lit);
        assertBoundedAfterInject("enforced [0,2]",      0,    2, lit);
    }
}

unittest { // UnenforcedIntTakesTheRawCast_documented
    // The other half of the same fact, asserted so that "enforceBounds is
    // what does the work" is a measured statement rather than a belief. If
    // `injectParamsInto` ever grows an unconditional clamp, THIS test fails
    // and the one above keeps passing — which is the correct way round for
    // the change to be noticed.
    int storage = 200;
    auto p = Param.int_("probe", "Probe", &storage, 200).min(20).max(2000);
    Param[] schema = [p];
    auto pj = parseJSON(`{"probe":1e39}`);
    import params : injectParamsInto;
    injectParamsInto(schema, pj);
    assert(storage == int.min,
        format("expected the unclamped float->int cast to yield int.min, got %d"
             ~ " — if injectParamsInto now clamps unconditionally, delete this"
             ~ " test and say so in doc/param_bounds_plan.md", storage));
}
