// Large-mesh /api/transform perf test (Stage D2 of doc/test_coverage_plan.md).
//
// /api/transform with a translate delta touches every selected vert,
// rebuilds the GPU buffer, and bumps mutation versions. On a heavy mesh
// (>1500 verts here) this exercises the whole-mesh fast path —
// regressions here typically come from accidentally falling into the
// per-vert CPU loop or from doubling the GPU upload work.
//
// Workload: cube → subdivide×3 (386 verts) → select-all → time
//           translate (0.001, 0, 0) per measured iteration.
//           Small delta keeps verts numerically stable across the
//           N+warmup iterations so the geometry doesn't drift far from
//           origin.
//
// Budget: 150 ms median. Typical observed timing is 15–30 ms; ×5
// margin catches genuine regressions without flaking on a noisy CI host.

import std.net.curl;
import std.json;
import std.conv : to;

import perf_helpers;

void main() {}

string baseUrl = "http://localhost:8080";

void runCmdJson(string id) {
    auto r = parseJSON(cast(string)post(baseUrl ~ "/api/command",
        `{"id":"` ~ id ~ `"}`));
    assert(r["status"].str == "ok", id ~ " failed: " ~ r.toString);
}

void selectAllVerts() {
    auto j = parseJSON(cast(string)get(baseUrl ~ "/api/model"));
    long n = j["vertexCount"].integer;
    string ids = "[";
    foreach (i; 0 .. n) {
        if (i > 0) ids ~= ",";
        ids ~= i.to!string;
    }
    ids ~= "]";
    auto r = parseJSON(cast(string)post(baseUrl ~ "/api/select",
        `{"mode":"vertices","indices":` ~ ids ~ `}`));
    assert(r["status"].str == "ok", "/api/select all failed");
}

unittest { // /api/transform translate on a 386-vert mesh stays under budget
    enum double BUDGET_MS = 150.0;

    post(baseUrl ~ "/api/reset", "");
    post(baseUrl ~ "/api/command", "select.typeFrom polygon");
    runCmdJson("mesh.subdivide");
    runCmdJson("mesh.subdivide");
    runCmdJson("mesh.subdivide");
    post(baseUrl ~ "/api/command", "select.typeFrom vertex");
    selectAllVerts();

    auto j = parseJSON(cast(string)get(baseUrl ~ "/api/model"));
    assert(j["vertexCount"].integer == 386,
        "setup: subdivide×3 should leave 386 verts; got " ~
        j["vertexCount"].integer.to!string);

    double median = timeMedianMs(5, () {
        auto r = parseJSON(cast(string)post(baseUrl ~ "/api/transform",
            `{"kind":"translate","delta":[0.001,0,0]}`));
        assert(r["status"].str == "ok",
            "/api/transform failed: " ~ r.toString);
    });

    assert(median < BUDGET_MS,
        "translate-all on 386-vert mesh median=" ~ fmtMs(median) ~
        " exceeds budget " ~ fmtMs(BUDGET_MS) ~
        " — check for accidental per-vert hot-loop fallback");
}
