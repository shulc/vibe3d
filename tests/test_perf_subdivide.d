// Subdivide perf test (Stage D1 of doc/test_coverage_plan.md).
//
// Catamull-Clark subdivision is on the hot path for both subpatch
// preview generation and the user-facing mesh.subdivide command. A
// quadratic loop creeping into adjacency build or face fan-out would
// blow up this test long before it became invisible to interactive
// users — picking up the regression here costs less than chasing the
// 200 ms hitch through the UI.
//
// Workload: reset → cube → 3 successive mesh.subdivide rounds (8 → 26
// → 98 → 386 verts), then time a 4th subdivide (386 → 1538).
//
// Budget: 800 ms median. The hot-path subdivide on a developer host
// runs in ~80-150 ms here; the budget is intentionally ~5× the typical
// timing so normal variance doesn't trip it, but a 10× regression will.

import std.net.curl;
import std.json;
import std.conv : to;

import perf_helpers;

void main() {}

string baseUrl = "http://localhost:8080";

void runCmd(string argstring) {
    auto r = parseJSON(cast(string)post(baseUrl ~ "/api/command", argstring));
    assert(r["status"].str == "ok",
        argstring ~ " failed: " ~ r.toString);
}

void runCmdJson(string id) {
    // Bareword `mesh.subdivide` reaches the argstring parser but doesn't
    // round-trip selection state the same way the JSON form does on
    // some hot paths — use the explicit JSON shape mesh.subdivide expects.
    auto r = parseJSON(cast(string)post(baseUrl ~ "/api/command",
        `{"id":"` ~ id ~ `"}`));
    assert(r["status"].str == "ok",
        id ~ " failed: " ~ r.toString);
}

long vertexCount() {
    auto j = parseJSON(cast(string)get(baseUrl ~ "/api/model"));
    return j["vertexCount"].integer;
}

void resetToSubdividedBase() {
    post(baseUrl ~ "/api/reset", "");
    post(baseUrl ~ "/api/command", "select.typeFrom polygon");
    foreach (_; 0 .. 3)
        runCmdJson("mesh.subdivide");
}

unittest { // mesh.subdivide on a 4×-subdivided cube stays under budget
    enum double BUDGET_MS = 800.0;

    double median = timeMedianMs(5, () {
        // Restart from the same 3-subdivide baseline every iteration so
        // each measured subdivide operates on a mesh of the same size.
        resetToSubdividedBase();
        runCmdJson("mesh.subdivide");
    });

    assert(median < BUDGET_MS,
        "mesh.subdivide median=" ~ fmtMs(median) ~
        " exceeds budget " ~ fmtMs(BUDGET_MS) ~
        " — check for new O(n²) loops in subdivision");

    // Sanity check: the final subdivide actually grew the mesh.
    // Cube → 26 → 98 → 386 → 1538 verts after the 4th subdivide pass.
    assert(vertexCount() == 1538,
        "subdivide×4 from a cube should produce 1538 verts; got " ~
        vertexCount().to!string ~
        " — subdivide topology may have changed");
}
