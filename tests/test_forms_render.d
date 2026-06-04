// FormsPanel write-path tests (forms_engine_plan Phase 4).
//
// Rendering itself is not headless-assertable (no pixel tests), but the WRITE
// path is: FormsPanel builds a write argstring by substituting the edited value
// for the control's `?` token (forms.substituteQuery) and dispatches it through
// the same command path /api/command uses. This test drives the EXACT line
// FormsPanel would build — by calling the same forms.substituteQuery the
// renderer calls — through /api/command and asserts it round-trips on a
// REACTIVE (primitive) tool, plus the value->token serialization (floats via
// %g) matches the wire format.
//
// Why a primitive (prim.sphere), not the transform tool: a bare (non-
// interactive) `tool.attr` re-builds a primitive's preview via
// onParamChanged/evaluate, but is INERT for the transform tool (which gains
// live editing only once the interactive flag + reEvaluate seam are wired,
// forms_engine_plan Phase 5 — and the interactive flag is programmatic-only, so
// it has no HTTP wire path). So the headless write-path assertion uses the
// reactive primitive; the transform interactive path is pinned by
// test_reevaluate / test_tool_query's live-session cases.
//
// SOURCE-BACKED test: `import forms;` pulls forms.d (and its transitive
// params/argstring unittest blocks, including the Phase-4 write-path helper
// tests) into the compile, AND lets this file build the write line through the
// renderer's own substituteQuery so the headless assertion exercises the real
// code path rather than a hand-typed argstring.

import forms : parseBinding, substituteQuery, valueToArgToken;

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
    return parseJSON(cast(string)post(baseUrl ~ path, body_));
}
JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

JSONValue query(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok",
        "query '" ~ line ~ "' failed: " ~ r.toString);
    assert("value" in r, "query '" ~ line ~ "' returned no value: " ~ r.toString);
    return r["value"];
}

void resetCube() {
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
}

void selectVerts(int[] idx) {
    string s = "[";
    foreach (i, v; idx) { if (i) s ~= ","; s ~= v.to!string; }
    s ~= "]";
    auto r = postJson("/api/select", `{"mode":"vertices","indices":` ~ s ~ `}`);
    assert(r["status"].str == "ok", "/api/select failed: " ~ r.toString);
}

double[3] vertexAt(int idx) {
    auto v = getJson("/api/model")["vertices"].array[idx].array;
    return [v[0].floating, v[1].floating, v[2].floating];
}

void assertVertex(int idx, double x, double y, double z, string label) {
    auto v = vertexAt(idx);
    assert(approxEqual(v[0], x) && approxEqual(v[1], y) && approxEqual(v[2], z),
        label ~ ": v" ~ idx.to!string ~ " expected (" ~ x.to!string ~ ","
        ~ y.to!string ~ "," ~ z.to!string ~ "), got (" ~ v[0].to!string ~ ","
        ~ v[1].to!string ~ "," ~ v[2].to!string ~ ")");
}

long undoCount() {
    return getJson("/api/history")["undo"].array.length;
}

// Reproduce a FormsPanel control-row write end-to-end: parse the row's `control`
// binding, substitute the edited value into the `?` slot exactly as the renderer
// does, parse the resulting argstring, and dispatch it via /api/command.
void formsWrite(string controlLine, JSONValue value) {
    auto b = parseBinding(controlLine);
    string line = substituteQuery(b, value);   // the renderer's own builder
    cmd(line);
}

// ---------------------------------------------------------------------------
// 1. A FormsPanel float write round-trips through the dispatch + query path.
//    Uses the renderer's own substituteQuery to build the line, proving the
//    write argstring FormsPanel emits is dispatchable + read-back-consistent.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("tool.set prim.sphere");

    // A control row bound to a real float attr. radius is reactive (the sphere
    // rebuilds on change).
    enum control = "tool.attr prim.sphere sizeX ?";
    formsWrite(control, JSONValue(1.25));
    auto v = query(control);
    assert(approxEqual(v.floating, 1.25),
        "forms float write should round-trip to 1.25, got " ~ v.toString);

    cmd("tool.set prim.sphere off");
}

// ---------------------------------------------------------------------------
// 2. A FormsPanel checkbox (bool) write round-trips.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("tool.set move");

    enum control = "tool.attr move T ?";
    formsWrite(control, JSONValue(true));
    auto t1 = query(control);
    assert(t1.type == JSONType.true_,
        "forms bool write true should read back true: " ~ t1.toString);
    formsWrite(control, JSONValue(false));
    auto t2 = query(control);
    assert(t2.type == JSONType.false_,
        "forms bool write false should read back false: " ~ t2.toString);

    cmd("tool.set move off");
}

// ---------------------------------------------------------------------------
// 3. A FormsPanel combo (intEnum) write round-trips: the combo writes the
//    entry's wire tag; the dispatch line is byte-clean (no quoting needed).
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("tool.set prim.sphere");

    enum control = "tool.attr prim.sphere method ?";
    // The renderer builds the line from the chosen tag string.
    auto b = parseBinding(control);
    assert(substituteQuery(b, JSONValue("qball"))
           == "tool.attr prim.sphere method qball");
    formsWrite(control, JSONValue("qball"));
    auto m = query(control);
    assert(m.str == "qball",
        "forms combo write should set method=qball, got " ~ m.str);

    cmd("tool.set prim.sphere off");
}

// ---------------------------------------------------------------------------
// 4. The serialized value token matches the wire %g format, so a forms write
//    is byte-identical to what the panel/HTTP would emit (no drift).
// ---------------------------------------------------------------------------
unittest {
    // float 1.0 emits "1" (%g drops trailing .0), 1.5 emits "1.5".
    assert(valueToArgToken(JSONValue(1.0)) == "1");
    assert(valueToArgToken(JSONValue(1.5)) == "1.5");
    auto b = parseBinding("tool.attr prim.sphere sizeX ?");
    assert(substituteQuery(b, JSONValue(1.0))
           == "tool.attr prim.sphere sizeX 1");
}

// ---------------------------------------------------------------------------
// 5. A bare forms float write on a primitive applies geometry but records no
//    undo entry — same as PropertyPanel today (no regression, no new undo for
//    the non-interactive path). Pinned via /api/history.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("tool.set prim.sphere");
    long undoBefore = getJson("/api/history")["undo"].array.length;
    formsWrite("tool.attr prim.sphere sizeX ?", JSONValue(0.8));
    long undoAfter = getJson("/api/history")["undo"].array.length;
    assert(undoAfter == undoBefore,
        "non-interactive forms write records no undo entry: before="
        ~ undoBefore.to!string ~ " after=" ~ undoAfter.to!string);
    cmd("tool.set prim.sphere off");
}

// ---------------------------------------------------------------------------
// 6. Phase 5 end-to-end — the SHIPPED transform form's Position-X (TX) control
//    line, built by the renderer's OWN substituteQuery, drives the reEvaluate()
//    seam on a live transform session: absolute apply (no accumulation) +
//    exactly ONE coalesced undo entry at drop.
//
//    This is the bridge between FormsPanel and the re-eval seam for the first
//    adopter (xfrm.transform). The interactive latch FormsPanel raises is UI-only
//    (no HTTP wire path), so — exactly as test_reevaluate does — we open the live
//    session with the testMode `tool.beginSession` hook so hasLiveEval() is true
//    and a dispatched `tool.attr` re-evaluates. The value-row write LINE is built
//    here by the renderer's substituteQuery from the exact `control:` string the
//    shipped transform.yaml uses, so this pins that the form's emitted line is the
//    one the seam consumes (absolute, one entry). The latch itself is covered by
//    the renderer code path; this asserts the contract it relies on.
// ---------------------------------------------------------------------------
unittest {
    // The transform form binds TX to this control line (config/forms/transform.yaml,
    // Position group). Build the write line via the renderer's own substituteQuery.
    enum txControl = "tool.attr xfrm.transform TX ?";

    resetCube();
    selectVerts([6]);                 // v6 = (0.5, 0.5, 0.5)
    cmd("tool.set xfrm.transform");

    long undoBefore = undoCount();

    // Open a live session (testMode hook) so the seam's hasLiveEval() branch fires
    // for the form-dispatched tool.attr — the headless proxy for FormsPanel's
    // interactive latch.
    cmd("tool.beginSession");
    assertVertex(6, 0.5, 0.5, 0.5, "beginSession opens session, moves nothing");

    // First form write (absolute): v6.x -> 0.5 + 0.05.
    formsWrite(txControl, JSONValue(0.05));
    assertVertex(6, 0.55, 0.5, 0.5, "first form TX write lands at +0.05 (seam absolute)");

    // Second form write: absolute, lands at +0.10 (NOT 0.15 — no accumulation).
    formsWrite(txControl, JSONValue(0.10));
    assertVertex(6, 0.60, 0.5, 0.5, "second form TX write is absolute (+0.10, not 0.15)");

    // Drop the tool → the whole session coalesces to exactly ONE undo entry.
    cmd("tool.set xfrm.transform off");
    assert(undoCount() == undoBefore + 1,
        "form value edits coalesce to ONE undo entry; before="
        ~ undoBefore.to!string ~ " after=" ~ undoCount().to!string);

    // One undo restores the original geometry.
    auto u = postJson("/api/undo", "");
    assert(u["status"].str == "ok", "undo failed: " ~ u.toString);
    assertVertex(6, 0.5, 0.5, 0.5, "one undo restores the original");
}
