module stage_helpers;

// Stage-conformance verifier — tool-port pipeline stage layer (task 0342).
// See doc/tasks/work/0342-stage-conformance-fixtures.md for the schema and
// doc/tool_port_process_v2_plan.md §3 for the "stage-conformance" rationale:
// test the toolpipe STAGE OUTPUT directly (ACEN center / AXIS frame /
// falloff weights) instead of re-deriving it from every tool's post-
// transform geometry. A tool that reuses the shared ACEN/AXIS/Falloff
// stages inherits this conformance for free — it only needs its own kernel
// fixtures (see tests/fixture_helpers.d, the end-geometry layer).
//
// Reads the same read-only /api/toolpipe/eval snapshot the reference-diff
// parity harness uses (source/app.d setToolPipeEvalProvider): runs
// pipeline.evaluate() ONCE against the current mesh/selection/camera and
// publishes actionCenter.center / axis.{right,up,fwd,...} / (when a
// falloff is active) falloffWeights. This is an IDLE evaluation, not a
// live interactive drag — see the 0342 task log's per-ACEN-mode
// disposition for which modes this idle snapshot is known to agree with a
// live haul's published packet, and which are flagged pending a live
// probe.
//
// Fixture schema `stage_conformance.v1` (one JSON drives a suite of named
// cases, mirroring runParitySuite's shape):
//   { "schema": "stage_conformance.v1", "stage": "acen"|"axis"|"falloff",
//     "name": "...", "tolerance": 1e-4,
//     "cases": [
//       { "name": "...",
//         "mesh_build": [ {"reset":true}, ... ],            // via runStep
//         "selection":  {"mode":"vertices|edges|polygons",   // optional;
//                        "coords": [...]},                   // via runStep's
//                                                             // {"select":...}
//         "pipe_setup": [ "actr.select", "tool.pipe.attr falloff type selection" ],
//                                                             // raw /api/command argstrings
//         "golden": { "center": [x,y,z] }                              // stage == "acen"
//                   | { "frame": {"right":[..],"up":[..],"fwd":[..]} }  // stage == "axis"
//                   | { "weights": [w0, w1, ...] }                     // stage == "falloff"
//                                                                       // (mesh vertex-index order)
//       } ] }
//
// `mesh_build`/`selection` reuse tests/fixture_helpers.d's `runStep` (the
// SAME step vocabulary as the end-geometry fixtures — reset/select/
// translate/...), and `pipe_setup` reuses its `cmd()` HTTP driver, so a
// stage fixture is authored with the exact same building blocks instead of
// a second copy of the HTTP-driving plumbing.
import std.json;
import std.net.curl : get;
import std.math     : fabs;
import std.format   : format;

import fixture_helpers : cmd, runStep, asDouble, jvec3;

// NB: the literal "localhost:8080" is rewritten per-worker by run_test.d
// for parallel runs (see tests/fixture_helpers.d's identical note) — keep
// it spelled out, do not build it dynamically.
private enum string BASE = "http://localhost:8080";

private JSONValue getEval(string ctx) {
    auto resp = cast(string) get(BASE ~ "/api/toolpipe/eval");
    auto j = parseJSON(resp);
    assert("error" !in j, format("%s: /api/toolpipe/eval returned an error: %s", ctx, resp));
    return j;
}

// Run one case's `mesh_build` + `selection` + `pipe_setup`, reusing
// fixture_helpers' drive helpers. `selection` is folded into the SAME
// {"select": {...}} step shape `runStep` already handles for the
// end-geometry fixtures, rather than re-deriving coordinate resolution here.
private void runCaseSetup(JSONValue cs, string cn) {
    if ("mesh_build" in cs)
        foreach (i, step; cs["mesh_build"].array) runStep(step, cn, "mesh_build", i);
    if ("selection" in cs) {
        JSONValue wrap;
        wrap["select"] = cs["selection"];
        runStep(wrap, cn, "selection", 0);
    }
    if ("pipe_setup" in cs)
        foreach (i, c; cs["pipe_setup"].array)
            cmd(c.str, cn ~ format(" pipe_setup[%d]", i));
}

/// `stage: "acen"` verifier — asserts /api/toolpipe/eval's
/// `actionCenter.center` against each case's frozen `golden.center`.
void runStageAcenSuite(string fixtureJson) {
    auto fx      = parseJSON(fixtureJson);
    string suite = ("name" in fx) ? fx["name"].str : "<stage-acen-suite>";
    double tolD  = ("tolerance" in fx) ? asDouble(fx["tolerance"]) : 1e-4;
    foreach (cs; fx["cases"].array) {
        string cn  = suite ~ "/" ~ (("name" in cs) ? cs["name"].str : "<case>");
        double tol = ("tolerance" in cs) ? asDouble(cs["tolerance"]) : tolD;
        runCaseSetup(cs, cn);

        auto ev = getEval(cn);
        assert("actionCenter" in ev,
            format("%s: /api/toolpipe/eval missing actionCenter", cn));
        auto got  = jvec3(ev["actionCenter"]["center"]);
        auto want = jvec3(cs["golden"]["center"]);
        foreach (c; 0 .. 3)
            assert(fabs(got[c] - want[c]) <= tol,
                format("%s: actionCenter.center[%d] expected %.6f, got %.6f (tol %.1e)",
                       cn, c, want[c], got[c], tol));
    }
}

/// `stage: "axis"` verifier — asserts /api/toolpipe/eval's `axis.{right,
/// up,fwd}` against each case's frozen `golden.frame`. Any of right/up/fwd
/// absent from `golden.frame` is simply not checked (lets a case pin only
/// the vectors its capture actually measured).
void runStageAxisSuite(string fixtureJson) {
    auto fx      = parseJSON(fixtureJson);
    string suite = ("name" in fx) ? fx["name"].str : "<stage-axis-suite>";
    double tolD  = ("tolerance" in fx) ? asDouble(fx["tolerance"]) : 1e-4;
    foreach (cs; fx["cases"].array) {
        string cn  = suite ~ "/" ~ (("name" in cs) ? cs["name"].str : "<case>");
        double tol = ("tolerance" in cs) ? asDouble(cs["tolerance"]) : tolD;
        runCaseSetup(cs, cn);

        auto ev = getEval(cn);
        assert("axis" in ev, format("%s: /api/toolpipe/eval missing axis", cn));
        auto axis = ev["axis"];
        auto want = cs["golden"]["frame"];
        foreach (key; ["right", "up", "fwd"]) {
            if (key !in want) continue;
            auto g = jvec3(axis[key]);
            auto w = jvec3(want[key]);
            foreach (c; 0 .. 3)
                assert(fabs(g[c] - w[c]) <= tol,
                    format("%s: axis.%s[%d] expected %.6f, got %.6f (tol %.1e)",
                           cn, key, c, w[c], g[c], tol));
        }
    }
}

/// `stage: "falloff"` verifier — asserts /api/toolpipe/eval's
/// `falloffWeights` (mesh vertex-index order, task 0342 Phase 1) against
/// each case's frozen `golden.weights`. Requires `pipe_setup` to activate a
/// falloff (e.g. `tool.pipe.attr falloff type selection`) — the block is
/// absent from the eval response otherwise, and this asserts loudly rather
/// than silently skipping.
void runStageFalloffSuite(string fixtureJson) {
    auto fx      = parseJSON(fixtureJson);
    string suite = ("name" in fx) ? fx["name"].str : "<stage-falloff-suite>";
    double tolD  = ("tolerance" in fx) ? asDouble(fx["tolerance"]) : 1e-4;
    foreach (cs; fx["cases"].array) {
        string cn  = suite ~ "/" ~ (("name" in cs) ? cs["name"].str : "<case>");
        double tol = ("tolerance" in cs) ? asDouble(cs["tolerance"]) : tolD;
        runCaseSetup(cs, cn);

        auto ev = getEval(cn);
        assert("falloffWeights" in ev,
            format("%s: /api/toolpipe/eval missing falloffWeights (falloff "
                   ~ "not enabled by pipe_setup?)", cn));
        auto got  = ev["falloffWeights"].array;
        auto want = cs["golden"]["weights"].array;
        assert(got.length == want.length,
            format("%s: falloffWeights length expected %d, got %d",
                   cn, want.length, got.length));
        foreach (i; 0 .. want.length)
            assert(fabs(asDouble(got[i]) - asDouble(want[i])) <= tol,
                format("%s: falloffWeights[%d] expected %.6f, got %.6f (tol %.1e)",
                       cn, i, asDouble(want[i]), asDouble(got[i]), tol));
    }
}
