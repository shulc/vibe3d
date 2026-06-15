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

// ---------------------------------------------------------------------------
// 6. Vec3 write round-trip — the editable X/Y/Z cluster. FormsPanel's
//    drawVec3Control serializes the full vector as a "%g,%g,%g" string token and
//    fires it through the row's binding; one component edit rewrites all three so
//    the others are preserved. Build the SAME line via the renderer's own
//    substituteQuery (a JSONValue string of "x,y,z"), assert it quotes the
//    comma-bearing token, dispatch it, and read the vec3 back (paramToJson emits
//    a [x,y,z] array). Covers the Vec3 write path the Linear falloff start/end
//    rows now use.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("tool.pipe.attr falloff type linear");

    enum startControl = "tool.pipe.attr falloff start ?";
    auto b = parseBinding(startControl);
    // The renderer builds the token as format("%g,%g,%g", x, y, z) → string value.
    string writeLine = substituteQuery(b, JSONValue("0,0,-5"));
    assert(writeLine == `tool.pipe.attr falloff start "0,0,-5"`, writeLine);
    cmd(writeLine);

    auto r = cmdRaw(startControl);
    assert(r["status"].str == "ok", "start query failed: " ~ r.toString);
    assert("value" in r, "start query returned no value: " ~ r.toString);
    auto v = r["value"];
    assert(v.type == JSONType.array && v.array.length == 3,
        "vec3 query should return a [x,y,z] array, got " ~ v.toString);
    double comp(size_t i) {
        auto e = v.array[i];
        return e.type == JSONType.float_ ? e.floating
             : e.type == JSONType.integer ? cast(double) e.integer : double.nan;
    }
    assert(approxEqual(comp(0), 0.0) && approxEqual(comp(1), 0.0)
        && approxEqual(comp(2), -5.0),
        "falloff start vec3 write should round-trip to (0,0,-5), got " ~ v.toString);

    cmd("tool.pipe.attr falloff type none");
}

// ---------------------------------------------------------------------------
// 7. Shape Preset dropdown — `shape` is now exposed in params() (was a legacy
//    drawProperties popup), so the form binds it as an enum combo. The row must
//    be visible under Linear and round-trip its wire tag.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("tool.pipe.attr falloff type linear");
    assert(rowVisible("shape"), "Linear: 'shape' (Shape Preset) row should be visible");

    enum shapeControl = "tool.pipe.attr falloff shape ?";
    auto b = parseBinding(shapeControl);
    string writeLine = substituteQuery(b, JSONValue("easeIn"));   // renderer's builder
    assert(writeLine == "tool.pipe.attr falloff shape easeIn", writeLine);
    cmd(writeLine);

    auto r = cmdRaw(shapeControl);
    assert(r["status"].str == "ok", "shape query failed: " ~ r.toString);
    assert(r["value"].str == "easeIn",
        "shape write should round-trip to 'easeIn', got " ~ r["value"].toString);

    cmd("tool.pipe.attr falloff type none");
}

// ---------------------------------------------------------------------------
// 8. Auto Size / Reverse action attrs — fire-only `cmd` rows. Reverse swaps the
//    Linear start/end; autosize is accepted (no-op without a selection). Both
//    drive the same tool.pipe.attr path the form's button rows dispatch.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("tool.pipe.attr falloff type linear");

    cmd(`tool.pipe.attr falloff start "1,2,3"`);
    cmd(`tool.pipe.attr falloff end "4,5,6"`);

    // Reverse swaps the endpoints — the SAME command the form's button fires.
    cmd("falloff.reverse");

    double[3] readVec(string attr) {
        auto r = cmdRaw("tool.pipe.attr falloff " ~ attr ~ " ?");
        assert(r["status"].str == "ok", attr ~ " query failed: " ~ r.toString);
        auto a = r["value"].array;
        double el(size_t i) {
            return a[i].type == JSONType.float_ ? a[i].floating
                 : a[i].type == JSONType.integer ? cast(double) a[i].integer : double.nan;
        }
        return [el(0), el(1), el(2)];
    }
    auto s = readVec("start");
    auto e = readVec("end");
    assert(approxEqual(s[0], 4) && approxEqual(s[1], 5) && approxEqual(s[2], 6),
        "reverse: start should now be (4,5,6)");
    assert(approxEqual(e[0], 1) && approxEqual(e[1], 2) && approxEqual(e[2], 3),
        "reverse: end should now be (1,2,3)");

    // autosize is accepted as a fire-only action (no selection → no-op, still
    // ok) — the SAME command the form's Auto Size X button fires.
    cmd("falloff.autosize x");

    cmd("tool.pipe.attr falloff type none");
}
