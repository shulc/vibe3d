// Parameter-domain gate — the SHIPPED routes, end to end (task 3020).
//
// A tool/command/stage parameter is written by three different doors, and
// before this task they disagreed about what a declared domain means:
//
//   1. `/api/command` + argstring positionals → `params.injectParamsInto`
//      (the JSON route). It read `.enforceBounds()`, but clamped with `<`/`>`
//      — both false against a NaN — and cast an Int BEFORE clamping it.
//   2. `tool.pipe.attr <stage> <attr> <value>` → the stage's `setAttrImpl`
//      (the wire-string route). It had NO bounds arm at all, and five stages
//      carry their own hand-written `s.to!float`, which accepts std.conv's
//      textual "nan"/"inf" sentinels.
//   3. prefs → `applyStickyToolDefaults` → `params.parseInto`, sharing (2)'s
//      parser and therefore (2)'s silence. Unit-pinned in
//      tests/unit/params_test.d; not drivable over HTTP.
//
// Everything below was measured RED on this tree before the fix, through
// exactly these calls, and each block carries its own boundary-value control:
// a check that reddens on correct input is worth no more than one that never
// reddens, so every refusal is paired with a legal value that must still land.
//
// The literal "localhost:8080" is rewritten per-worker by run_test.d — keep it
// spelled out (see tests/fixture_helpers.d).

import std.json;
import std.net.curl : get, post;
import std.format   : format;
import std.math     : fabs;
import std.algorithm : canFind;

void main() {}

private enum string BASE = "http://localhost:8080";

private JSONValue jpost(string path, string body_) {
    return parseJSON(post(BASE ~ path, body_));
}

private void reset() {
    auto r = jpost("/api/reset", "");
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString());
}

/// `/api/command` with a JSON params object. Returns the raw answer — the
/// caller decides whether ok or error is the expected outcome.
private JSONValue command(string id, string paramsJson) {
    return jpost("/api/command",
                 `{"id":"` ~ id ~ `","params":` ~ paramsJson ~ `}`);
}

/// One argstring line through `/api/script`. Returns the raw answer.
private JSONValue script(string line) {
    return jpost("/api/script", line ~ "\n");
}

private JSONValue model() {
    return parseJSON(cast(string)get(BASE ~ "/api/model"));
}

/// Vertex 0 of the live mesh, or a marker triple when the serialiser reported
/// a non-finite there (it prints `null` for one — see http_json.d).
private double[3] vertex0() {
    auto m = model();
    auto v = m["vertices"][0];
    double[3] out_;
    foreach (i; 0 .. 3) {
        assert(v[i].type != JSONType.null_,
               format("vertex 0 component %d is NON-FINITE — /api/model says %s",
                      i, m["nonFinite"].toString()));
        out_[i] = v[i].type == JSONType.integer
                    ? cast(double)v[i].integer : v[i].floating;
    }
    return out_;
}

private size_t nonFiniteCount() {
    return cast(size_t)model()["nonFinite"]["count"].integer;
}

private void armTransformScaleOnly() {
    assert(script("tool.set xfrm.transform")["status"].str == "ok");
    assert(script("tool.attr xfrm.transform T false")["status"].str == "ok");
    assert(script("tool.attr xfrm.transform R false")["status"].str == "ok");
}

// ---------------------------------------------------------------------------
// Block 1 — the JSON route refuses a non-finite, and the mesh survives.
//
// `1e300` is the reachable input, and it is reachable precisely BECAUSE it is
// finite: JSON has no NaN literal and the argstring grammar has no exponent,
// so the audit's "a NaN defeats the clamp" arrives as a perfectly ordinary
// double whose narrowing to `float` is infinite. Measured before the fix:
// this pair of calls put a non-finite in all 24 vertex components
// (`/api/model` reported `{"count":24,"first":{...,"value":"-nan"}}`).
// ---------------------------------------------------------------------------
unittest {
    reset();
    armTransformScaleOnly();

    auto r = command("tool.attr",
                     `{"_positional":["xfrm.transform","SX",1e300]}`);
    assert(r["status"].str == "error",
           "a float param whose narrowing overflows to infinity must be "
           ~ "REFUSED at the wire edge, got: " ~ r.toString());
    assert(r["message"].str.canFind("must be a finite number"),
           "the refusal must say WHY — got: " ~ r["message"].str);

    // And the refusal has to have written nothing: apply, then look at the mesh.
    command("tool.doApply", `{}`);
    assert(nonFiniteCount() == 0,
           format("the refused write must leave the mesh finite, "
                  ~ "/api/model reports %s", model()["nonFinite"].toString()));
    auto v = vertex0();
    assert(fabs(v[0] - (-0.5)) < 1e-6,
           format("…and untouched: vertex0.x = %.6f, expected -0.5", v[0]));
}

// Block 1's control: a LEGAL scale on the very same route still lands.
// A gate that refuses correct input is exactly as bad as one that refuses
// nothing, so this is not decoration.
unittest {
    reset();
    armTransformScaleOnly();

    auto r = command("tool.attr",
                     `{"_positional":["xfrm.transform","SX",3.0]}`);
    assert(r["status"].str == "ok",
           "SX=3 is an ordinary scale and must be accepted: " ~ r.toString());
    command("tool.doApply", `{}`);
    auto v = vertex0();
    assert(fabs(v[0] - (-1.5)) < 1e-6,
           format("SX=3 must actually scale: vertex0.x = %.6f, expected -1.5",
                  v[0]));
}

// ---------------------------------------------------------------------------
// Block 2 — the Int bounds arm runs BEFORE the cast.
//
// `mesh.smooth`'s `iter` is `.min(0).max(256).enforceBounds()`. `1e18` is a
// finite float with no `int` to land on, so `cast(int)` used to produce the
// x86 indefinite integer (`int.min`) and the clamp then lifted THAT to the
// param's MINIMUM: measured, `iter:1e18` behaved exactly like `iter:0` and
// left the cube untouched, while `iter:1000000` correctly collapsed it.
//
// The discriminating assertion is therefore against the CEILING's result, not
// merely "something happened": a test that only asserted "the mesh changed"
// would be green on the broken code for `iter:1000000` and says nothing.
// ---------------------------------------------------------------------------
unittest {
    // The ceiling's own answer, measured on this tree, as the oracle.
    reset();
    auto rc = command("mesh.smooth", `{"iter":256,"strength":1.0}`);
    assert(rc["status"].str == "ok", rc.toString());
    auto atCeiling = vertex0();

    // The untouched cube, so the two outcomes are known to differ at all.
    reset();
    auto untouched = vertex0();
    assert(fabs(atCeiling[0] - untouched[0]) > 1e-3,
           "PRECONDITION: iter=256 must visibly differ from iter=0, or this "
           ~ "block cannot separate the ceiling from the floor");

    reset();
    auto r = command("mesh.smooth", `{"iter":1e18,"strength":1.0}`);
    assert(r["status"].str == "ok", r.toString());
    auto huge = vertex0();
    foreach (i; 0 .. 3)
        assert(fabs(huge[i] - atCeiling[i]) < 1e-6,
               format("iter:1e18 must clamp UP to the declared ceiling (256), "
                      ~ "not down to the floor: component %d is %.6f, the "
                      ~ "ceiling gives %.6f, the floor gives %.6f",
                      i, huge[i], atCeiling[i], untouched[i]));
}

// Block 2's control: the declared FLOOR is a legal value, not a refusal.
unittest {
    reset();
    auto r = command("mesh.smooth", `{"iter":0,"strength":1.0}`);
    assert(r["status"].str == "ok",
           "iter=0 is inside the declared domain and must be accepted: "
           ~ r.toString());
    auto v = vertex0();
    assert(fabs(v[0] - (-0.5)) < 1e-6,
           format("iter=0 must be a no-op smooth, got vertex0.x = %.6f", v[0]));
}

// ---------------------------------------------------------------------------
// Block 3 — the wire-string (stage) route refuses a non-finite.
//
// These six lines are the audit's own examples plus the rest of the family.
// Every one of them answered `status:ok` before the fix and left the sentinel
// in the stage (`/api/toolpipe` read back `"dist": "nan"`). Note `symmetry
// epsilon`: that stage had a hand-written `if (v <= 0.0f) return false`, which
// refused a NEGATIVE epsilon and waved the NaN through — the same
// every-comparison-is-false hole as `enforceBounds`, in a second place.
// ---------------------------------------------------------------------------
unittest {
    reset();
    static struct Case { string line; string stage; string attr; }
    immutable Case[] refuse = [
        Case("tool.pipe.attr falloff dist nan",          "falloff",      "dist"),
        Case("tool.pipe.attr falloff dist inf",          "falloff",      "dist"),
        Case("tool.pipe.attr symmetry epsilon nan",      "symmetry",     "epsilon"),
        Case("tool.pipe.attr symmetry epsilon inf",      "symmetry",     "epsilon"),
        Case("tool.pipe.attr snap innerRange nan",       "snap",         "innerRange"),
        Case("tool.pipe.attr actionCenter cenX inf",     "actionCenter", "cenX"),
        Case("tool.pipe.attr workplane rotY nan",        "workplane",    "rotY"),
    ];
    foreach (c; refuse) {
        auto r = script(c.line);
        assert(r["status"].str == "error",
               format("`%s` must be REFUSED — a non-finite stage attribute "
                      ~ "poisons every frame derived from it. Got: %s",
                      c.line, r.toString()));
        auto msg = r["results"][0]["message"].str;
        assert(msg.canFind("rejected attr"),
               format("`%s` must surface the route's own refusal wording, "
                      ~ "got: %s", c.line, msg));
    }
    // …and nothing landed: every one of them still reads its default back.
    auto tp = parseJSON(cast(string)get(BASE ~ "/api/toolpipe"));
    foreach (ref s; tp["stages"].array) {
        immutable id = s["id"].str;
        foreach (c; refuse) {
            if (c.stage != id) continue;
            if (auto a = c.attr in s["attrs"].object) {
                immutable got = a.str;
                assert(got != "nan" && got != "inf" && got != "-inf",
                       format("stage %s attr %s still holds the refused "
                              ~ "sentinel %s", id, c.attr, got));
            }
        }
    }
}

// Block 3's control: legal stage values — including the boundary `0` on a
// range that a naive "must be positive" gate would wrongly refuse — still land
// and read back verbatim.
unittest {
    reset();
    static struct Ok { string line; string stage; string attr; string want; }
    immutable Ok[] accept = [
        Ok("tool.pipe.attr falloff dist 4",           "falloff",      "dist",       "4"),
        Ok("tool.pipe.attr symmetry epsilon 0.0001",  "symmetry",     "epsilon",    "0.0001"),
        Ok("tool.pipe.attr snap innerRange 24",       "snap",         "innerRange", "24"),
        Ok("tool.pipe.attr snap innerRange 0",        "snap",         "innerRange", "0"),
        Ok("tool.pipe.attr actionCenter cenX -1.5",   "actionCenter", "cenX",       "-1.5"),
        Ok("tool.pipe.attr workplane rotY 90",        "workplane",    "rotY",       "90"),
    ];
    foreach (c; accept) {
        auto r = script(c.line);
        assert(r["status"].str == "ok",
               format("`%s` is a legal value and must be ACCEPTED: %s",
                      c.line, r.toString()));
        auto tp = parseJSON(cast(string)get(BASE ~ "/api/toolpipe"));
        string got;
        bool found;
        foreach (ref s; tp["stages"].array) {
            if (s["id"].str != c.stage) continue;
            if (auto a = c.attr in s["attrs"].object) { got = a.str; found = true; }
        }
        assert(found, format("stage %s does not expose %s", c.stage, c.attr));
        assert(got == c.want,
               format("`%s` must actually land: %s.%s reads back %s, expected %s",
                      c.line, c.stage, c.attr, got, c.want));
    }
}

// ---------------------------------------------------------------------------
// Block 4 — the JSON route refuses a non-numeric token, instead of silently
// writing zero (task 3021).
//
// The argstring grammar has no float exponent / nan / inf literal, so a
// typo'd numeric attr value (`SX zzz`) hands through `tool.attr`'s
// `_positional` array as a JSON STRING, not a bad number. `params._jsonNum`
// used to answer `0.0` for any non-numeric node, and that 0.0 sailed straight
// through `paramGateFloat` (0.0 is perfectly finite) — measured before the
// fix: `status:ok`, `v0.x` collapsed to 0.0. `_jsonNum` now answers NaN for a
// non-numeric node, which is the SAME value the sibling `1e300` case in Block
// 1 already refuses — one fallback change, no new refusal wording.
// ---------------------------------------------------------------------------
unittest {
    reset();
    armTransformScaleOnly();

    auto r = command("tool.attr",
                     `{"_positional":["xfrm.transform","SX","zzz"]}`);
    assert(r["status"].str == "error",
           "a non-numeric token on a float param must be REFUSED, not "
           ~ "silently coerced to zero, got: " ~ r.toString());
    assert(r["message"].str.canFind("must be a finite number"),
           "the refusal must say WHY — got: " ~ r["message"].str);

    command("tool.doApply", `{}`);
    assert(nonFiniteCount() == 0,
           format("the refused write must leave the mesh finite, "
                  ~ "/api/model reports %s", model()["nonFinite"].toString()));
    auto v = vertex0();
    assert(fabs(v[0] - (-0.5)) < 1e-6,
           format("…and untouched: vertex0.x = %.6f, expected -0.5", v[0]));
}

// Block 4's control: an ordinary numeric string ("3", not a bare 3.0 JSON
// number) still lands — the refusal must not have widened to catch every
// JSON string, only the ones that fail to parse as a number.
unittest {
    reset();
    armTransformScaleOnly();

    auto r = command("tool.attr",
                     `{"_positional":["xfrm.transform","SX",3.0]}`);
    assert(r["status"].str == "ok",
           "SX=3 is an ordinary scale and must be accepted: " ~ r.toString());
    command("tool.doApply", `{}`);
    auto v = vertex0();
    assert(fabs(v[0] - (-1.5)) < 1e-6,
           format("SX=3 must actually scale: vertex0.x = %.6f, expected -1.5",
                  v[0]));
}
