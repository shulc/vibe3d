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
// WHAT TASK 3020 CHANGED UNDER THIS TEST
// --------------------------------------
// The first block is unchanged and still green: an ENFORCED int is clamped
// into its declared range whatever the wire hands it. The second block was
// rewritten — an UNENFORCED int handed an unrepresentable value is now
// REFUSED rather than given the raw `int.min`, because the cast now runs
// AFTER the bounds arm and a value with no int to land on has no honest
// answer. The `int.min` forensics above are kept as the record of what the
// cast does; they are no longer what this path produces.
//
// MUTATION (this test is not finished without it)
// -----------------------------------------------
// Remove `.enforceBounds()` from `source/tools/slice/loop_slice_tool.d:615`
// and this test fails with:
//   "enforced [20,2000]: 1e39 injected into a [20,2000] Int gave ..."
// (before task 3020 the same mutation reddened it with the value
// -2147483648; it now reddens because the unenforced param REFUSES and the
// refusal escapes `assertBoundedAfterInject` as an uncaught exception)
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

unittest { // UnenforcedIntIsREFUSED_notCast (task 3020)
    // The other half of the same fact. This block used to assert that an
    // unenforced int took the RAW cast — `int.min` — and said, in as many
    // words, that if `injectParamsInto` ever changed here the change should be
    // noticed HERE. It changed, and it did.
    //
    // The change is NOT the unconditional clamp that sentence anticipated:
    // there is still no ceiling to clamp an unenforced param to, and inventing
    // one would be an edit the caller never asked for. What the value gets
    // instead is a REFUSAL — the same policy `document.sanitizeItemXform`
    // settled for a non-finite item xform, and now applied to any number with
    // no `int` to land on. `enforceBounds` is still exactly what decides
    // whether the value is CLAMPED (the block above) or REFUSED (this one);
    // what is gone is the third outcome, silently writing garbage.
    // Recorded in doc/param_bounds_plan.md.
    int storage = 200;
    auto p = Param.int_("probe", "Probe", &storage, 200).min(20).max(2000);
    Param[] schema = [p];
    auto pj = parseJSON(`{"probe":1e39}`);
    import params : injectParamsInto;
    bool threw = false;
    try injectParamsInto(schema, pj);
    catch (Exception e) {
        threw = true;
        assert(e.msg == "param 'probe' is not a representable integer", e.msg);
    }
    assert(threw,
        "an unenforced Int handed a value with no int to land on must be "
        ~ "REFUSED, not silently cast to int.min");
    assert(storage == 200,
        format("a refused write must leave the field at its prior value, got %d",
               storage));

    // Control, and the reason this is a refusal rather than a blanket clamp:
    // an unenforced param with a perfectly representable value is still
    // written through unclamped, declared hints and all.
    auto pjOk = parseJSON(`{"probe":9999}`);
    injectParamsInto(schema, pjOk);
    assert(storage == 9999,
        format("an unenforced [20,2000] hint must stay UI-only for a "
             ~ "representable value, got %d", storage));
}
