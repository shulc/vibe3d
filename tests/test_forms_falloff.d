// Forms-engine Phase 6 — falloff stage form: dynamic (value-driven) row
// visibility + stage-binding write round-trip.
//
// The shipped config/forms/falloff.yaml binds each value row to a
// `tool.pipe.attr falloff <attr> ?` line. FalloffStage.params() is FILTERED by
// the active falloff type (Linear exposes start/end, Radial exposes
// center/size, Element exposes mode/dist/connect, ...), and the forms resolver
// hides any row whose attr is absent from the live params() — so switching the
// falloff type changes which rows show, with NO inline conditionals in the YAML.
//
// That visibility decision is the SAME one the HTTP `tool.pipe.attr falloff
// <attr> ?` query makes: the query resolves against the live (type-filtered)
// params() and returns status=error for an attr the active type doesn't expose,
// status=ok otherwise. So this test drives the exact stage-query path the form's
// rows resolve through and asserts the per-type flip directly — a headless proxy
// for "row appears / disappears on type switch". (The renderer's hide path
// itself — resolveControl returning found=false → drawControl early-return — is
// already covered by the Phase 4 forms.d resolver unittests pulled in via
// `import forms` below; this file pins the LIVE, end-to-end type-switch flip.)
//
// SOURCE-BACKED: `import forms` pulls forms.d's inline resolver unittests into
// this compile, and lets the write-path case build the exact line FormsPanel
// would emit via the renderer's own substituteQuery/parseBinding.

import forms : parseBinding, substituteQuery;

import std.net.curl;
import std.json;
import std.math : fabs;
import std.conv : to;

void main() {}

string baseUrl = "http://localhost:8080";

bool approxEqual(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

// Dispatch a command, asserting it succeeded.
void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

// Raw dispatch — caller inspects status (used for the present/absent probes).
JSONValue cmdRaw(string line) {
    return postJson("/api/command", line);
}

// True iff a `?` stage query resolves (attr present in the CURRENT, type-
// filtered params()). This is exactly the row-visibility decision the forms
// resolver makes via resolveControl(found).
bool rowVisible(string attr) {
    auto r = cmdRaw("tool.pipe.attr falloff " ~ attr ~ " ?");
    return r["status"].str == "ok";
}

void resetCube() {
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
}

// ---------------------------------------------------------------------------
// 1. Type-switch flip: Linear exposes start/end; switching to Radial flips
//    those off and center/size on. Same attrs the shipped falloff.yaml binds.
// ---------------------------------------------------------------------------
unittest {
    resetCube();

    cmd("tool.pipe.attr falloff type linear");
    assert(rowVisible("start"), "Linear: 'start' row should be visible");
    assert(rowVisible("end"),   "Linear: 'end' row should be visible");
    assert(!rowVisible("center"),
        "Linear: 'center' (radial-only) row should be hidden");
    assert(!rowVisible("size"),
        "Linear: 'size' (radial-only) row should be hidden");

    // Flip the type — the SAME rows must invert visibility, no YAML change.
    cmd("tool.pipe.attr falloff type radial");
    assert(!rowVisible("start"),
        "Radial: 'start' (linear-only) row should now be hidden");
    assert(!rowVisible("end"),
        "Radial: 'end' (linear-only) row should now be hidden");
    assert(rowVisible("center"), "Radial: 'center' row should now be visible");
    assert(rowVisible("size"),   "Radial: 'size' row should now be visible");

    cmd("tool.pipe.attr falloff type none");
}

// ---------------------------------------------------------------------------
// 2. type == None exposes NO config rows: every shipped value row hides. This
//    is what makes the falloff section collapse to nothing when falloff is off.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("tool.pipe.attr falloff type none");
    foreach (attr; ["start", "end", "center", "size", "axis", "dist", "mode",
                    "connect", "screenCx", "screenSize", "transparent",
                    "lassoStyle", "softBorder"])
        assert(!rowVisible(attr),
            "type=None should hide every config row, but '" ~ attr
            ~ "' resolved");
}

// ---------------------------------------------------------------------------
// 3. Element vs Selection both expose `dist` (Element = Range, Selection =
//    Steps): the single shared `dist` row stays visible across that switch
//    while the Element-only mode/connect rows flip off. Pins that the shared
//    row binds correctly under both (label is the live Param.label, not in YAML).
// ---------------------------------------------------------------------------
unittest {
    resetCube();

    cmd("tool.pipe.attr falloff type element");
    assert(rowVisible("dist"),    "Element: 'dist' row visible");
    assert(rowVisible("mode"),    "Element: 'mode' row visible");
    assert(rowVisible("connect"), "Element: 'connect' row visible");

    cmd("tool.pipe.attr falloff type selection");
    assert(rowVisible("dist"),     "Selection: shared 'dist' row still visible");
    assert(!rowVisible("mode"),    "Selection: 'mode' (element-only) row hidden");
    assert(!rowVisible("connect"), "Selection: 'connect' (element-only) row hidden");

    cmd("tool.pipe.attr falloff type none");
}

// ---------------------------------------------------------------------------
// 4. Custom-shape rows (in/out) are shape-gated, not type-gated: only visible
//    when shape == Custom, independent of the active type. Exercises the OTHER
//    value-driven filter in falloff.params() (the shape branch).
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("tool.pipe.attr falloff type linear");

    cmd("tool.pipe.attr falloff shape smooth");
    assert(!rowVisible("in"),  "non-Custom shape: 'in' row hidden");
    assert(!rowVisible("out"), "non-Custom shape: 'out' row hidden");

    cmd("tool.pipe.attr falloff shape custom");
    assert(rowVisible("in"),  "Custom shape: 'in' row visible");
    assert(rowVisible("out"), "Custom shape: 'out' row visible");

    cmd("tool.pipe.attr falloff shape smooth");
    cmd("tool.pipe.attr falloff type none");
}

// ---------------------------------------------------------------------------
// 5. Write round-trip through a falloff value row's binding, built by the
//    renderer's OWN substituteQuery (the exact line FormsPanel emits): write
//    via tool.pipe.attr, read back via the `?` query. Covers the stage-namespace
//    write path that the falloff form's rows use.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("tool.pipe.attr falloff type element");

    // The shipped form binds Element's Range to this control line.
    enum distControl = "tool.pipe.attr falloff dist ?";
    auto b = parseBinding(distControl);
    string writeLine = substituteQuery(b, JSONValue(2.5));   // renderer's builder
    assert(writeLine == "tool.pipe.attr falloff dist 2.5", writeLine);
    cmd(writeLine);

    auto r = cmdRaw(distControl);
    assert(r["status"].str == "ok", "dist query failed: " ~ r.toString);
    assert("value" in r, "dist query returned no value: " ~ r.toString);
    auto v = r["value"];
    double got = v.type == JSONType.float_ ? v.floating
               : v.type == JSONType.integer ? cast(double) v.integer : double.nan;
    assert(approxEqual(got, 2.5),
        "falloff dist write should round-trip to 2.5, got " ~ v.toString);

    cmd("tool.pipe.attr falloff type none");
}
