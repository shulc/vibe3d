// Module unittests for `params`, moved verbatim out of source/params.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.params_test;

import math : Vec3;
import std.json : JSONValue, JSONType;
import params;

unittest {
    static immutable IntEnumEntry[] tbl = [
        IntEnumEntry(0, "off",   "Off"),
        IntEnumEntry(1, "width", "Width"),
        IntEnumEntry(2, "depth", "Depth"),
    ];

    // wireTagForValue — match, no-match fallback (default + explicit).
    assert(wireTagForValue(tbl, 1) == "width");
    assert(wireTagForValue(tbl, 99) == "99");                 // default fallback
    assert(wireTagForValue(tbl, 99, "?") == "?");              // explicit fallback

    // valueForWireTag — match, no-match.
    int v;
    assert(valueForWireTag(tbl, "depth", v) && v == 2);
    assert(!valueForWireTag(tbl, "bogus", v));

    // tableCoversEnum — complete vs missing member.
    assert(tableCoversEnum(tbl, [0, 1, 2]));
    assert(!tableCoversEnum(tbl, [0, 1, 2, 3]));
    assert(tableCoversEnum(tbl, []));   // vacuously true

    // A `static immutable` table passes straight into intEnum_ without .dup
    // (the OBJ-1 widening this helper block depends on).
    int backing = 1;
    auto p = Param.intEnum_("k", "K", &backing, tbl, 0);
    assert(p.intEnumValues.length == 3);
}

unittest {
    // isStickyCapturable — plain float capturable; readonly/transient/array
    // kinds excluded, independently and in combination.
    float f = 0.0f;
    auto plain = Param.float_("dist", "Distance", &f, 0.0f);
    assert(isStickyCapturable(plain));

    auto ro = Param.float_("dist", "Distance", &f, 0.0f).readonly();
    assert(!isStickyCapturable(ro));

    auto tr = Param.float_("dist", "Distance", &f, 0.0f).transient();
    assert(!isStickyCapturable(tr));

    uint[] arr;
    auto ia = Param.intArray_("indices", "Indices", &arr);
    assert(!isStickyCapturable(ia));

    Vec3[] varr;
    auto va = Param.vec3Array_("verts", "Verts", &varr);
    assert(!isStickyCapturable(va));

    // hidden() alone does not exclude — only readonly/transient/array do.
    auto hid = Param.float_("dist", "Distance", &f, 0.0f).hidden();
    assert(isStickyCapturable(hid));

    auto both = Param.float_("dist", "Distance", &f, 0.0f).readonly().transient();
    assert(!isStickyCapturable(both));
}

unittest {
    // Flags — default clear, setters set bits, accessors read them, chaining
    // composes. The bitfield consolidates the former standalone hidden_ bool.
    int i = 0;
    auto p0 = Param.int_("n", "N", &i, 0);
    assert(!p0.hidden_ && !p0.readonly_);
    assert(p0.flags == ParamFlags.None);

    auto ph = Param.int_("n", "N", &i, 0).hidden();
    assert(ph.hidden_ && !ph.readonly_);

    auto pr = Param.int_("n", "N", &i, 0).readonly();
    assert(pr.readonly_ && !pr.hidden_);

    // Both flags compose, and order/independence holds with hint setters.
    auto pb = Param.int_("n", "N", &i, 0).readonly().hidden().min(0).max(9);
    assert(pb.hidden_ && pb.readonly_);
    assert((pb.flags & ParamFlags.Hidden) && (pb.flags & ParamFlags.ReadOnly));
}

unittest {
    // Angle hint — default clear; .angle() sets isAngle; composes with other
    // chainable setters and does not bleed onto a non-angle float. forms_render
    // reads hints.isAngle to widen the default drag step (0.1/px vs 0.001/px);
    // the resulting ImGui drag SPEED has no headless signal, so this asserts the
    // hint propagates through the Param the renderer resolves (drag feel is
    // manual-verify).
    float f = 0.0f;
    auto plain = Param.float_("dist", "Distance", &f, 0.0f);
    assert(!plain.hints.isAngle);

    auto ang = Param.float_("RX", "Rotate X", &f, 0.0f).angle();
    assert(ang.hints.isAngle);

    // Composes with min/max/fmt without clobbering isAngle, and explicit .step()
    // still wins at the render site (asserted there via hasStep).
    auto ang2 = Param.float_("RY", "Rotate Y", &f, 0.0f).angle().min(-360.0f).max(360.0f);
    assert(ang2.hints.isAngle);
    assert(ang2.hints.hasMinF && ang2.hints.hasMaxF);
}

unittest {
    // Bool — set when value differs from default
    bool b = false;
    auto p = Param.bool_("flag", "Flag", &b, false);
    assert(!isUserSet(p));
    b = true;
    assert(isUserSet(p));
}

unittest {
    // Int — set when value differs from default
    int i = 4;
    auto p = Param.int_("segs", "Segments", &i, 4);
    assert(!isUserSet(p));
    i = 8;
    assert(isUserSet(p));
}

unittest {
    // Float — NaN-vs-NaN treated as not user-set (e.g. widthR default NaN)
    float f = float.nan;
    auto p = Param.float_("widthR", "Width R", &f, float.nan);
    assert(!isUserSet(p));   // NaN equals NaN here
    f = 0.05f;
    assert(isUserSet(p));    // explicit value
    f = float.nan;
    assert(!isUserSet(p));   // back to NaN, not user-set again
}

unittest {
    // Float — standard numeric compare (no epsilon, any delta counts)
    float f = 0.1f;
    auto p = Param.float_("width", "Width", &f, 0.1f);
    assert(!isUserSet(p));
    f = 0.10001f;
    assert(isUserSet(p));
}

unittest {
    // Enum — string-tag compare
    string mode = "offset";
    auto p = Param.enum_("mode", "Mode", &mode,
                         [["offset","Offset"],["width","Width"]], "offset");
    assert(!isUserSet(p));
    mode = "width";
    assert(isUserSet(p));
}

unittest {
    // String — empty-string default is not user-set
    string s = "";
    auto p = Param.string_("label", "Label", &s, "");
    assert(!isUserSet(p));
    s = "hello";
    assert(isUserSet(p));
    s = "";
    assert(!isUserSet(p));
}

unittest {
    // IntEnum — int-tag compare
    int v = 0;
    auto p = Param.intEnum_("mode", "Mode", &v,
        [IntEnumEntry(0, "offset", "Offset"),
         IntEnumEntry(1, "width",  "Width")],
        0);
    assert(!isUserSet(p));
    v = 1;
    assert(isUserSet(p));
}

unittest {
    // Vec3 — component-wise compare
    Vec3 v = Vec3(0, 0, 0);
    auto p = Param.vec3_("from", "From", &v, Vec3(0, 0, 0));
    assert(!isUserSet(p));
    v.x = 0.5f;
    assert(isUserSet(p));
    v = Vec3(0, 0, 0);
    assert(!isUserSet(p));
}

unittest {
    // IntArray — empty slice is not user-set; non-empty is.
    uint[] arr;
    auto p = Param.intArray_("indices", "Indices", &arr);
    assert(!isUserSet(p));
    arr = [0u, 5u, 7u];
    assert(isUserSet(p));
    arr = [];
    assert(!isUserSet(p));
}

unittest {
    // Vec3Array — empty slice is not user-set; non-empty is.
    Vec3[] arr;
    auto p = Param.vec3Array_("before", "Before", &arr);
    assert(!isUserSet(p));
    arr = [Vec3(0, 0, 0), Vec3(1, 2, 3)];
    assert(isUserSet(p));
    arr = [];
    assert(!isUserSet(p));
}

unittest {
    // fmtFloatWire — the exact value set task 0409 pins for byte-identity
    // across argstring._fmtFloat / stringifyParam / forms.fmtFloatG.
    assert(fmtFloatWire(0.0)              == "0");
    assert(fmtFloatWire(1.0)              == "1");
    assert(fmtFloatWire(-1.0)             == "-1");
    assert(fmtFloatWire(0.5)              == "0.5");
    assert(fmtFloatWire(1e-7)             == "1e-07");
    assert(fmtFloatWire(-3.25)            == "-3.25");
    assert(fmtFloatWire(1e20)             == "1e+20");
    assert(fmtFloatWire(123456.789)       == "123457");  // %g rounds to 6 sig figs
    assert(fmtFloatWire(cast(double)0.1f) == "0.1");

    // NaN/Inf sentinels — the semantics argstring._fmtFloat's doc comment
    // calls out as load-bearing for NaN-default params (e.g. widthR).
    assert(fmtFloatWire(double.nan)       == "nan");
    assert(fmtFloatWire(double.infinity)  == "inf");
    assert(fmtFloatWire(-double.infinity) == "-inf");
}

unittest {
    // float vs. double input produce identical tokens for every value in the
    // pinned set — the premise that lets argstring._fmtFloat(float) delegate
    // to this double-taking helper with no observable behaviour change
    // (float->double widening is exact, and %g's rounding is a function of
    // the real value, not the storage width — verified here rather than
    // assumed).
    import std.format : format;
    immutable float[] vals = [0.0f, 1.0f, -1.0f, 0.5f, 1e-7f, -3.25f, 1e20f,
                               123456.789f, 0.1f];
    // LHS = the pre-refactor _fmtFloat behaviour (raw %g on the float); RHS =
    // the double-taking helper it now delegates to. Equal ⇒ the widen is
    // observably lossless, which is the premise being verified (not assumed).
    foreach (v; vals)
        assert(format("%g", v) == fmtFloatWire(v),
               format("%g", v) ~ " vs " ~ fmtFloatWire(v));
}

unittest {
    // parseInto / stringifyParam round-trip for the kinds that support a
    // scalar string token (moved here verbatim from toolpipe/stage.d, which
    // had no dedicated unit coverage of its own — this is fresh coverage,
    // not a relocation of an existing test).
    bool  b = false;
    int   i = 0;
    float f = 0.0f;
    string mode = "offset";
    int   ie = 0;
    string s = "";
    Vec3  v = Vec3(0, 0, 0);

    auto pb  = Param.bool_ ("b", "B", &b, false);
    auto pi  = Param.int_  ("i", "I", &i, 0);
    auto pf  = Param.float_("f", "F", &f, 0.0f);
    auto pe  = Param.enum_ ("mode", "Mode", &mode,
                            [["offset","Offset"],["width","Width"]], "offset");
    auto pie = Param.intEnum_("ie", "IE", &ie,
        [IntEnumEntry(0, "off", "Off"), IntEnumEntry(1, "on", "On")], 0);
    auto ps  = Param.string_("s", "S", &s, "");
    auto pv  = Param.vec3_  ("v", "V", &v, Vec3(0, 0, 0));

    assert(parseInto(pb, "true"));   assert(b == true);
    assert(stringifyParam(pb) == "true");
    assert(parseInto(pb, "0"));      assert(b == false);
    assert(!parseInto(pb, "nope"));  // unrecognized bool token -> false, b unchanged
    assert(b == false);

    assert(parseInto(pi, "42"));     assert(i == 42);
    assert(stringifyParam(pi) == "42");
    assert(!parseInto(pi, "abc"));   assert(i == 42);   // unchanged on parse failure

    assert(parseInto(pf, "0.5"));    assert(f == 0.5f);
    assert(stringifyParam(pf) == "0.5");

    assert(parseInto(pe, "width")); assert(mode == "width");
    assert(stringifyParam(pe) == "width");
    assert(!parseInto(pe, "bogus")); assert(mode == "width");

    assert(parseInto(pie, "on"));   assert(ie == 1);
    assert(stringifyParam(pie) == "on");
    assert(!parseInto(pie, "bogus")); assert(ie == 1);

    assert(parseInto(ps, "hello")); assert(s == "hello");
    assert(stringifyParam(ps) == "hello");

    assert(parseInto(pv, "1,2,3"));
    assert(v.x == 1 && v.y == 2 && v.z == 3);
    assert(stringifyParam(pv) == "1,2,3");
    assert(!parseInto(pv, "1,2"));   // wrong arity -> false, v unchanged
    assert(v.x == 1 && v.y == 2 && v.z == 3);

    // Array kinds are out of scope for the string wire form (JSON injection
    // is their canonical path) — parseInto rejects, stringifyParam is inert.
    uint[] arr;
    auto pa = Param.intArray_("arr", "Arr", &arr);
    assert(!parseInto(pa, "1,2,3"));
    assert(stringifyParam(pa) == "");
}

unittest { // paramSchemaJson — wire shape per kind + hint family + enforceBounds
    import std.json : parseJSON, JSONType;

    // Int with int hints and enforcement — the shape tests/test_param_bounds.d
    // Block A reads (it fails a count-like param whose enforceBounds is false
    // or whose max is absent).
    int count = 7;
    auto pi = Param.int_("count", "Count", &count, 1).min(1).max(256).enforceBounds();
    assert(paramSchemaJson(pi) ==
        `{"name":"count","kind":"Int","enforceBounds":true,"value":7,"min":1,"max":256}`,
        paramSchemaJson(pi));

    // Float with float hints, no enforcement — min/max come out of the FLOAT
    // family, and enforceBounds is false unless opted in. `%s` on a whole
    // float prints `0`/`1`, so the bound lands on the wire as a JSON integer;
    // read it through `.get!double` rather than `.floating`, which is what a
    // consumer that only cares about the NUMBER has to do.
    float ratio = 0.25f;
    auto pf = Param.float_("ratio", "Ratio", &ratio, 0.0f).min(0.0f).max(1.0f);
    auto jf = parseJSON(paramSchemaJson(pf));
    assert(jf["kind"].str           == "Float");
    assert(jf["enforceBounds"].type == JSONType.false_);
    assert(jf["value"].get!double   == 0.25);
    assert(jf["min"].get!double     == 0.0);
    assert(jf["max"].get!double     == 1.0);

    // No hints at all → neither key is emitted (Block A's "max=none" branch).
    bool flag = true;
    auto pb = Param.bool_("flag", "Flag", &flag, false);
    auto jb = parseJSON(paramSchemaJson(pb));
    assert(jb["kind"].str == "Bool");
    assert(jb["value"].type == JSONType.true_);
    assert("min" !in jb.object);
    assert("max" !in jb.object);

    // Array form: `[]` for an empty schema, and one entry per Param otherwise.
    assert(paramsSchemaJson([]) == "[]");
    auto arr = parseJSON(paramsSchemaJson([pi, pf]));
    assert(arr.array.length == 2);
    assert(arr[0]["name"].str == "count");
    assert(arr[1]["name"].str == "ratio");
}

unittest {
    // paramToJson round-trips each scalar kind through injectParamsInto.
    import std.math : fabs;

    bool b = true;
    auto pb = Param.bool_("flag", "F", &b, false);
    assert(paramToJson(pb).type == JSONType.true_);

    int i = 7;
    auto pi = Param.int_("segs", "S", &i, 0);
    assert(paramToJson(pi).integer == 7);

    float f = 1.5f;
    auto pf = Param.float_("w", "W", &f, 0.0f);
    assert(fabs(paramToJson(pf).floating - 1.5) < 1e-6);

    string s = "hi";
    auto ps = Param.string_("lbl", "L", &s, "");
    assert(paramToJson(ps).str == "hi");

    string mode = "width";
    auto pe = Param.enum_("mode", "M", &mode,
                          [["offset","Offset"],["width","Width"]], "offset");
    assert(paramToJson(pe).str == "width");
    auto ch = choicesOf(pe);
    assert(ch.length == 2 && ch[1][0] == "width" && ch[1][1] == "Width");

    Vec3 v = Vec3(1, 2, 3);
    auto pv = Param.vec3_("c", "C", &v, Vec3(0, 0, 0));
    auto jv = paramToJson(pv);
    assert(jv.type == JSONType.array && jv.array.length == 3);
    assert(fabs(jv.array[0].floating - 1) < 1e-6);
    assert(fabs(jv.array[2].floating - 3) < 1e-6);

    int ie = 1;
    auto pie = Param.intEnum_("k", "K", &ie,
        [IntEnumEntry(0, "off", "Off"), IntEnumEntry(1, "width", "Width")], 0);
    assert(paramToJson(pie).str == "width");
    auto iech = choicesOf(pie);
    assert(iech.length == 2 && iech[0][0] == "off" && iech[0][1] == "Off");

    // Round-trip: box then inject into a fresh field.
    float f2 = 0.0f;
    auto pf2 = Param.float_("w", "W", &f2, 0.0f);
    JSONValue pj = JSONValue(cast(JSONValue[string]) null);
    pj["w"] = paramToJson(pf);   // box live 1.5
    auto arr = [pf2];
    injectParamsInto(arr, pj);
    assert(fabs(f2 - 1.5) < 1e-6);
}

unittest {
    // injectParamsInto clamps Int/Float writes to declared .min()/.max()
    // hints (task 0314) ONLY when the Param opts in via `.enforceBounds()`
    // — both directions, and a value already in-range passes through
    // unchanged. Mirrors prim.cube's `segmentsR` (`.min(1).max(64)`), the
    // concrete DoS repro.
    import std.conv : to;

    int    segs = 3;
    float  radius = 10.0f;
    auto ps = Param.int_("segmentsR", "Radius Segments", &segs, 3)
        .min(1).max(64).enforceBounds();
    auto pr = Param.float_("radius", "Radius", &radius, 10.0f)
        .min(0.0f).max(20.0f).enforceBounds();
    auto arr = [ps, pr];

    JSONValue pj = JSONValue(cast(JSONValue[string]) null);
    pj["segmentsR"] = JSONValue(1000);   // way over max(64)
    pj["radius"]    = JSONValue(-5.0);   // under min(0.0)
    injectParamsInto(arr, pj);
    assert(segs   == 64, "segmentsR should clamp to declared max(64), got " ~ segs.to!string);
    assert(radius == 0.0f, "radius should clamp to declared min(0.0), got " ~ radius.to!string);

    // Below min(1) also clamps (not just the max side) once opted in.
    JSONValue pj2 = JSONValue(cast(JSONValue[string]) null);
    pj2["segmentsR"] = JSONValue(-10);
    injectParamsInto(arr, pj2);
    assert(segs == 1, "segmentsR should clamp to declared min(1), got " ~ segs.to!string);

    // In-range values pass through unchanged.
    JSONValue pj3 = JSONValue(cast(JSONValue[string]) null);
    pj3["segmentsR"] = JSONValue(10);
    pj3["radius"]    = JSONValue(0.3);
    injectParamsInto(arr, pj3);
    assert(segs == 10, "in-range segmentsR should pass through, got " ~ segs.to!string);
    assert(radius > 0.29f && radius < 0.31f,
        "in-range radius should pass through, got " ~ radius.to!string);

    // A Param with hints but NO `.enforceBounds()` opt-in is never clamped
    // (task 0314's design: hints stay UI-only metadata unless a Param
    // explicitly asks for headless enforcement). This is the case that
    // matters for commands.mesh.sweep's `count` (`.min(2)`, no
    // `.enforceBounds()`), whose own apply()-time check
    // (`if (count_ < 2) return false;`) is the real authority — see
    // tests/test_mesh_sweep.d's "count < 2 → error, mesh unchanged".
    int countLike = 8;
    auto pc = Param.int_("count", "Count", &countLike, 8).min(2);
    auto arrC = [pc];
    JSONValue pj4 = JSONValue(cast(JSONValue[string]) null);
    pj4["count"] = JSONValue(1);   // below min(2), NOT enforced
    injectParamsInto(arrC, pj4);
    assert(countLike == 1,
        "non-opted-in min hint must pass through unclamped (caller's own "
        ~ "domain check decides accept/reject), got " ~ countLike.to!string);

    // A Param with no hints at all is likewise never clamped, however
    // large the value (enforceBounds() with no min/max hint is a no-op).
    int unbounded = 0;
    auto pu = Param.int_("free", "Free", &unbounded, 0);
    auto arrU = [pu];
    JSONValue pj5 = JSONValue(cast(JSONValue[string]) null);
    pj5["free"] = JSONValue(99999);
    injectParamsInto(arrU, pj5);
    assert(unbounded == 99999, "hint-less param must not be clamped");
}

// ---------------------------------------------------------------------------
// Task 3020 — the numeric gate: what a declared domain means, on BOTH routes.
//
// Before this task `parseInto` had no bounds arm and no finiteness check, and
// `injectParamsInto`'s clamp ran after the Int cast. Each block below was
// measured red on that code; see tests/test_param_bounds_gate.d for the same
// three defects driven through the shipped HTTP routes.
// ---------------------------------------------------------------------------

unittest { // NON-FINITE IS REFUSED, on both routes, and writes nothing.
    import std.conv : to;
    import std.math : isNaN;

    // -- the wire-string route. `to!float` accepts std.conv's textual
    //    sentinels, which is how `tool.pipe.attr falloff dist nan` used to be
    //    answered `status ok`.
    float f = 2.5f;
    auto pf = Param.float_("dist", "Distance", &f, 1.0f);
    assert(!parseInto(pf, "nan"),  "parseInto must REFUSE a NaN token");
    assert(f == 2.5f, "a refused parse must leave the field untouched");
    assert(!parseInto(pf, "inf"),  "parseInto must REFUSE an inf token");
    assert(!parseInto(pf, "-inf"), "parseInto must REFUSE a -inf token");
    assert(f == 2.5f);
    // …and the control: an ordinary value on the same call still lands.
    assert(parseInto(pf, "0.25"), "a finite token must still be accepted");
    assert(f == 0.25f);

    // -- the JSON route. A NaN cannot be a JSON literal, but it reaches this
    //    function from in-process callers (paramToJson round-trips a live
    //    field), and `1e300` — an ordinary finite double — becomes an INFINITE
    //    float in the narrowing, which is the door that was actually open.
    float g = 7.0f;
    auto pg = Param.float_("w", "W", &g, 1.0f);
    auto arr = [pg];
    JSONValue pj = JSONValue(cast(JSONValue[string]) null);
    pj["w"] = JSONValue(1e300);
    bool threw = false;
    try injectParamsInto(arr, pj);
    catch (Exception e) {
        threw = true;
        assert(e.msg == "param 'w' must be a finite number", e.msg);
    }
    assert(threw, "a double whose float narrowing overflows must be refused");
    assert(g == 7.0f, "and the field must be untouched");

    // Control: the largest value that DOES narrow finitely is accepted.
    JSONValue pj2 = JSONValue(cast(JSONValue[string]) null);
    pj2["w"] = JSONValue(3.0e38);          // < float.max (~3.4e38)
    injectParamsInto(arr, pj2);
    assert(g > 2.9e38f, "a representable magnitude must still be written");
}

unittest { // THE BOUNDS ARM RUNS BEFORE THE INT CAST.
    import std.conv : to;
    int iter = 5;
    auto p = Param.int_("iter", "Iterations", &iter, 1)
                .min(0).max(256).enforceBounds();
    auto arr = [p];

    // 1e18 has no `int` to land on: `cast(int)` yields the x86 indefinite
    // integer (int.min), so a clamp AFTER the cast lifted it to the param's
    // MINIMUM. Measured on the shipped route, `mesh.smooth {"iter":1e18}`
    // behaved exactly like `iter:0`.
    JSONValue pj = JSONValue(cast(JSONValue[string]) null);
    pj["iter"] = JSONValue(1e18);
    injectParamsInto(arr, pj);
    assert(iter == 256,
        "an over-max float must clamp UP to the declared ceiling, not down to "
        ~ "the floor via a destroyed cast — got " ~ iter.to!string);

    // The other direction, and the boundary values themselves.
    JSONValue pjLo = JSONValue(cast(JSONValue[string]) null);
    pjLo["iter"] = JSONValue(-1e18);
    injectParamsInto(arr, pjLo);
    assert(iter == 0, "an under-min float must clamp to the floor, got "
        ~ iter.to!string);
    foreach (int b; [0, 1, 255, 256]) {
        JSONValue pjB = JSONValue(cast(JSONValue[string]) null);
        pjB["iter"] = JSONValue(b);
        injectParamsInto(arr, pjB);
        assert(iter == b, "the boundary value " ~ b.to!string
            ~ " is INSIDE the domain and must pass through, got "
            ~ iter.to!string);
    }

    // An UNENFORCED int has no ceiling to clamp to, so a value with no int to
    // land on is refused rather than silently becoming int.min.
    int free = 9;
    auto pu = Param.int_("free", "Free", &free, 0);
    auto arrU = [pu];
    JSONValue pjU = JSONValue(cast(JSONValue[string]) null);
    pjU["free"] = JSONValue(1e18);
    bool threw = false;
    try injectParamsInto(arrU, pjU);
    catch (Exception e) {
        threw = true;
        assert(e.msg == "param 'free' is not a representable integer", e.msg);
    }
    assert(threw, "an unrepresentable int on an unbounded param must be refused");
    assert(free == 9, "and the field must be untouched");
    // Control: a large-but-representable int still passes through unclamped.
    JSONValue pjOk = JSONValue(cast(JSONValue[string]) null);
    pjOk["free"] = JSONValue(2_000_000_000);
    injectParamsInto(arrU, pjOk);
    assert(free == 2_000_000_000, "a hint-less param must not be clamped");
}

unittest { // THE FLAG IS NO LONGER INERT ON THE WIRE-STRING ROUTE.
    //
    // `applyStickyToolDefaults` (tool_presets.d) re-applies a prefs-stored
    // value string onto a freshly built tool through `parseInto`. `prim.box`'s
    // `segmentsX` is `.min(1).max(64).enforceBounds()` — a DoS ceiling on an
    // allocation scaler (doc/param_bounds_plan.md) — so before this task a
    // prefs entry re-armed an unbounded segment count that the JSON route
    // clamps. Same declared domain, two routes, one answer.
    import std.conv : to;
    int segs = 3;
    auto p = Param.int_("segmentsX", "Segments X", &segs, 1)
                .min(1).max(64).enforceBounds();
    assert(parseInto(p, "100000"), "an over-max value is CLAMPED, not refused");
    assert(segs == 64, "…to the declared ceiling, got " ~ segs.to!string);
    assert(parseInto(p, "-7"));
    assert(segs == 1, "…and to the declared floor, got " ~ segs.to!string);
    // Boundary values are inside the domain and must survive verbatim.
    foreach (int b; [1, 2, 63, 64]) {
        assert(parseInto(p, b.to!string));
        assert(segs == b, "boundary " ~ b.to!string ~ " must pass through, got "
            ~ segs.to!string);
    }

    float w = 0.5f;
    auto pf = Param.float_("blend", "Blend", &w, 0.5f)
                .min(0.0f).max(1.0f).enforceBounds();
    assert(parseInto(pf, "9.0"));
    assert(w == 1.0f, "an over-max float clamps on this route too");
    assert(parseInto(pf, "0"));
    assert(w == 0.0f, "the floor is a LEGAL value, not a refusal");

    // A Param WITHOUT the opt-in is still unclamped here, exactly as on the
    // JSON route — the flag is what decides, on both.
    int count = 8;
    auto pc = Param.int_("count", "Count", &count, 8).min(2);
    assert(parseInto(pc, "1"));
    assert(count == 1, "a hint without the opt-in stays UI-only");

    // This route keeps its STRICT integer grammar: the gate applies the
    // declared domain, it does not relax what counts as an int token.
    int strict = 5;
    auto pstrict = Param.int_("n", "N", &strict, 5).min(0).max(10).enforceBounds();
    assert(!parseInto(pstrict, "2.5"),
        "a non-integral token stays a parse failure, not a silent truncation");
    assert(strict == 5);
    assert(!parseInto(pstrict, "99999999999"),
        "a token with no int to land on stays a parse failure");
    assert(strict == 5);
}

unittest { // A Vec3 write is ATOMIC across its three components.
    Vec3 v = Vec3(1, 2, 3);
    auto p = Param.vec3_("start", "Start", &v, Vec3(0, 0, 0));
    assert(!parseInto(p, "9,nan,9"),
        "a non-finite component must refuse the whole vector");
    assert(v.x == 1 && v.y == 2 && v.z == 3,
        "…and leave NO component written (x/y precede the bad z/y)");
    assert(!parseInto(p, "1,2,inf"));
    assert(v.x == 1 && v.y == 2 && v.z == 3);
    assert(parseInto(p, "4,5,6"), "a finite triple must still be accepted");
    assert(v.x == 4 && v.y == 5 && v.z == 6);
}

unittest { // Prepared candidate injection owns names in schema order.
    import std.json : parseJSON;

    float width = 1;
    int segments = 2;
    auto schema = [
        Param.float_("width", "Width", &width, 1),
        Param.int_("segments", "Segments", &segments, 2),
    ];
    auto input = parseJSON(`{"segments": 7, "ignored": 9, "width": 3.5}`);
    auto changed = injectPreparedParamsInto(schema, input);
    assert(width == 3.5f && segments == 7);
    assert(changed == ["width", "segments"],
        "prepared parameter names lost schema order or admitted unknown input");

    input = JSONValue.init;
    bool refused;
    try injectPreparedParamsInto(schema, input);
    catch (Exception) refused = true;
    assert(refused, "prepared injection weakened the strict JSON object contract");
}
