// test_param_cast_overflow.d — task 1410.
//
// THE WIRE MAY NOT PUT A BOUNDED Int OUTSIDE ITS BOUNDS.
//
// Registry-driven, like tests/test_param_bounds.d Block A: the subject list is
// read from `GET /api/registry?params=1` at run time, so a tool param added
// tomorrow is covered tomorrow, with no edit here. For every Int tool param
// that declares BOTH a `min` and a `max`, this drives `1e39` at it over real
// HTTP and reads the value back, and asserts what came out is inside the
// declared interval.
//
// WHY 1e39 AND WHY THAT IS THE WHOLE EXTREME SET
// ----------------------------------------------
// `injectParamsInto` (source/params.d:788) narrows every numeric JSON node
// through `_jsonFloat` (:927), which returns a `float`. `1e39` exceeds float's
// range, so it arrives as `float.infinity`, and `int iv = cast(int)…` at :809
// is then undefined behaviour — the cast happens BEFORE the clamp at :810-813,
// and the clamp only runs when the param opted into `enforceBounds`.
// Everything else in the neighbourhood is unreachable and is deliberately not
// probed: `1e999` makes std.json throw `Range error` before our code runs; a
// bare `nan` in an argstring parses as a STRING and `_jsonFloat` silently
// answers 0.0f; and the argstring number grammar has no exponent at all, so
// `1e39` can only be delivered as JSON (which is what the `_positional` form
// below does).
//
// WHY THIS IS A TEST AND NOT A SANITIZER RUN
// ------------------------------------------
// This was to have been UBSan's job. Measured on the shipped LDC 1.42.0:
// `--fsanitize=` accepts address, thread, memory, leak and fuzzer, and
// REJECTS undefined, integer, bounds and float-cast-overflow. No UBSan
// runtime ships in that tarball, so the cheapest phase of task 1410's plan had
// no mechanism. Asking the question behaviourally needs no sanitizer at all
// and runs in BOTH ordinary lanes — this file in `run_test.d`, and
// tests/unit/param_cast_overflow_test.d in `dub test --config=tests` — plus
// the release-shaped instrumented build (`--build=check-release`), which is
// the one that matters because release is what ships.
//
// WHAT IT FOUND WHEN IT WAS FIRST RUN
// -----------------------------------
// 35 bounded Int tool params, all 35 readable, exactly 2 outside their
// declared interval — the 2 that declared bounds without `.enforceBounds()`:
//     mesh.loopSliceTool.length  [20,2000]  →  -2147483648
//     pen.currentPoint           [-1,1024]  →  -2147483648
// The other 33 clamped correctly. Both were fixed by adding `.enforceBounds()`
// (doc/param_bounds_plan.md's two-layer contract, task 0365, applied to two
// stragglers). So this file has a real positive AND negative population and
// cannot pass by covering nothing.
//
// MUTATION: delete `.enforceBounds()` from
// source/tools/slice/loop_slice_tool.d:615 and this test fails naming that
// param, its interval and -2147483648.
import http_client : testBaseUrl;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv    : to;
import std.format  : format;
import std.array   : join;

alias BASE = testBaseUrl;

void main() {}

private JSONValue postCmd(string body_) {
    return parseJSON(post(BASE ~ "/api/command", body_));
}

unittest { // BoundedIntTooLParamsSurviveWireInfinity
    auto reg = parseJSON(cast(string) get(BASE ~ "/api/registry?params=1"));
    assert("toolParams" in reg.object,
        "registry has no toolParams — is ?params=1 wired?");

    struct Subject { string tool, name; long lo, hi; bool enforced; }
    Subject[] subjects;
    foreach (tid, ps; reg["toolParams"].object) {
        foreach (p; ps.array) {
            if (p["kind"].str != "Int")    continue;
            if ("min" !in p || "max" !in p) continue;
            subjects ~= Subject(tid, p["name"].str,
                                p["min"].integer, p["max"].integer,
                                p["enforceBounds"].type == JSONType.true_);
        }
    }

    // A sweep that swept nothing would pass silently — the inert-measurement
    // class this whole task exists to avoid. 35 subjects were live when this
    // was written; the floor is deliberately well under that so ordinary
    // additions and removals do not trip it, and deliberately above zero.
    assert(subjects.length >= 20,
        format("expected >=20 bounded Int tool params, found %d — the sweep "
             ~ "found nothing to sweep", subjects.length));

    string[] failures;
    string[] unreadable;
    int checked = 0;

    foreach (s; subjects) {
        // Activating the tool is what makes `tool.attr` address it. A tool
        // that refuses to arm headlessly is not a failure of this property —
        // it is recorded as unreadable below and counted, so a build where
        // everything stopped answering cannot read as a pass.
        postCmd(format(`{"id":"tool.set","params":{"_positional":["%s","on"]}}`,
                       s.tool));

        auto before = postCmd(format("tool.attr %s %s ?", s.tool, s.name));
        if (before["status"].str != "ok" || "value" !in before) {
            unreadable ~= s.tool ~ "." ~ s.name;
            continue;
        }
        ++checked;

        // JSON `_positional`, not an argstring: the argstring number grammar
        // has no exponent, so `1e39` cannot be expressed there at all.
        postCmd(format(
            `{"id":"tool.attr","params":{"_positional":["%s","%s",1e39]}}`,
            s.tool, s.name));

        auto after = postCmd(format("tool.attr %s %s ?", s.tool, s.name));
        assert(after["status"].str == "ok" && "value" in after,
            format("%s.%s: read-back failed after injection: %s",
                   s.tool, s.name, after.toString));
        auto got = after["value"].integer;
        if (got < s.lo || got > s.hi)
            failures ~= format("%s.%s: declared [%d,%d] (enforceBounds=%s) "
                             ~ "took the value %d from JSON 1e39",
                               s.tool, s.name, s.lo, s.hi,
                               s.enforced ? "true" : "false", got);
    }

    // Restore: drop whatever tool the sweep left armed and put the scene back.
    // run_test.d resets between tests anyway, but a test that leaves a tool
    // active is a test that can only be debugged by reading the runner.
    postCmd(`{"id":"tool.set","params":{"_positional":["none","on"]}}`);
    post(BASE ~ "/api/command", commandBody("scene.reset"));

    assert(unreadable.length * 2 < subjects.length,
        format("%d of %d bounded Int tool params could not be read back — the "
             ~ "sweep is measuring almost nothing: %s",
               unreadable.length, subjects.length, unreadable.join(", ")));

    assert(failures.length == 0,
        "Int param(s) with declared bounds reachable outside them from the "
      ~ "wire — add `.enforceBounds()` (doc/param_bounds_plan.md, task 0365) "
      ~ "or a kernel cap:\n  " ~ failures.join("\n  ")
      ~ format("\n(checked %d of %d subjects)", checked, subjects.length));
}
