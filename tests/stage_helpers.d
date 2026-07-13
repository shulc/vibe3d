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

import fixture_helpers : cmd, runStep, asDouble, jvec3, requireProvenance;
// Reused for the Mode.Element live-pick verifier (see
// runStageAcenElementLivePick below) — camera/viewport projection math is
// already duplicated once in drag_helpers.d (from source/math.d) for the
// interactive-drag tests; a third copy here would be a needless drift risk.
import drag_helpers : Vec3, CameraState, fetchCamera, viewportFromCamera,
                      projectToWindow, playAndWait;

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
    requireProvenance(fx, suite);
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
    requireProvenance(fx, suite);
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
    requireProvenance(fx, suite);
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

// ---------------------------------------------------------------------
// Mode.Element LIVE-PICK verifier (task 0342 Phase 3, review finding R3).
// ---------------------------------------------------------------------
//
// `runStageAcenSuite`'s generic mesh_build/selection/pipe_setup vocabulary
// can only reach `ActionCenterStage.computeCenter`'s Mode.Element FALLBACK
// tiers (userPin / elementCenter()) — there is no HTTP step that writes
// `elementVerts_` directly (by design: it is only ever set by a REAL
// click-pick, `XfrmTransformTool.tryPickElement` -> `takeVert`/`takeEdge`/
// `takeFace` -> `notifyAcenElementVerts`). Driving `userPlacedCenter` via
// `tool.pipe.attr actionCenter userPlacedX/Y/Z` and calling that "element
// parity" would silently test the WRONG tier — computeCenter's Element arm
// is `if (liveElementCenter(elc)) return elc; if (userPin.placed) return
// userPin.center; return elementCenter();`, so liveElementCenter always
// wins once populated, making the userPin path a dead branch whenever a
// pick has actually happened — a fixture that only ever exercises userPin
// would be a false green for "element parity".
//
// This driver instead fires a REAL /api/play-events click: hovers each
// mesh face at an OFF-CENTRE point (halfway from the face centroid toward
// one of its own corners — same recipe as
// tests/test_element_pick_face_clickpoint.d) until the hovered face
// matches, then sends a bare mouse-down with NO follow-up motion (Element
// mode tracks the picked ring's LIVE position, so an actual drag would move
// the vertices and the "golden" would have to chase a moving target;
// reading back immediately after DOWN isolates the pick itself from any
// drag). The expected center is the picked face's OWN vertex average,
// computed from live /api/model data — not a frozen JSON golden, since
// screen-space picking is inherently camera/viewport-dependent (unlike the
// other stage-acen cases). Two assertions close the loop:
//   1. actionCenter.center == the face centroid (proves liveElementCenter
//      fired and is what answered).
//   2. actionCenter.center != the (off-centre) click point (proves this is
//      NOT the userPin/click-point fallback tier — the two tiers would be
//      indistinguishable if the click had landed ON the centroid, which is
//      exactly why the click point is deliberately off-centre).
private string viewportLine(CameraState cam) {
    return format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
                  cam.vpX, cam.vpY, cam.width, cam.height);
}

private string hoverLogAt(CameraState cam, int x, int y) {
    string log = viewportLine(cam);
    foreach (i; 0 .. 5)
        log ~= format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
                      50.0 + i * 20.0, x, y);
    return log;
}

private string downOnlyLog(CameraState cam, int x, int y) {
    return viewportLine(cam) ~
        format(`{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n", x, y);
}

private string upLog(CameraState cam, int x, int y) {
    return viewportLine(cam) ~
        format(`{"t":50.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n", x, y);
}

private int hoverFaceOf(JSONValue ev) {
    if ("hover" !in ev || "face" !in ev["hover"]) return -1;
    return cast(int) ev["hover"]["face"].integer;
}

/// Drives a real element click-pick (see the block comment above) against
/// whatever mesh/camera the caller has already set up (default: a fresh
/// `/api/reset` cube + vibe3d's default camera — both deterministic, so the
/// picked face is the same on every run). `presetId` activates the
/// falloff.element + actionCenter.mode=element pipe combo in one preset
/// (`xfrm.elementMove`'s config/tool_presets.yaml block sets BOTH).
void runStageAcenElementLivePick(string presetId = "xfrm.elementMove",
                                 double tol = 1e-4) {
    enum string cn = "acen_element_livepick";

    runStep(parseJSON(`{"reset":true}`), cn, "mesh_build", 0);
    cmd("tool.set " ~ presetId ~ " on", cn);

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    auto model = parseJSON(cast(string) get(BASE ~ "/api/model"));
    auto faces = model["faces"].array;
    auto verts = model["vertices"].array;

    Vec3 vtx(size_t i) {
        auto c = jvec3(verts[i]);
        return Vec3(cast(float) c[0], cast(float) c[1], cast(float) c[2]);
    }

    int  chosen = -1;
    Vec3 faceCentroid, clickPoint;
    int  cpx, cpy;
    foreach (fi, f; faces) {
        auto idx = f.array;
        if (idx.length < 3) continue;
        Vec3 c = Vec3(0, 0, 0);
        foreach (vi; idx) c = c + vtx(cast(size_t) vi.integer);
        c = c / cast(float) idx.length;
        Vec3 v0 = vtx(cast(size_t) idx[0].integer);
        // Off-centre on purpose — see the block comment's assertion 2.
        Vec3 click = c + (v0 - c) * 0.5f;
        float sx, sy;
        if (!projectToWindow(click, vp, sx, sy)) continue;
        int px = cast(int) sx, py = cast(int) sy;
        playAndWait(hoverLogAt(cam, px, py));
        if (hoverFaceOf(getEval(cn)) == cast(int) fi) {
            chosen = cast(int) fi; faceCentroid = c; clickPoint = click;
            cpx = px; cpy = py;
            break;
        }
    }
    assert(chosen >= 0, cn ~ ": no pickable face found for a live element pick "
                             ~ "(default camera/cube should always yield one)");

    playAndWait(downOnlyLog(cam, cpx, cpy));
    auto ev = getEval(cn);
    assert("actionCenter" in ev, format("%s: /api/toolpipe/eval missing actionCenter", cn));
    auto got = jvec3(ev["actionCenter"]["center"]);
    double[3] wantCentroid = [faceCentroid.x, faceCentroid.y, faceCentroid.z];
    double[3] wantNotClick = [clickPoint.x, clickPoint.y, clickPoint.z];

    foreach (c; 0 .. 3)
        assert(fabs(got[c] - wantCentroid[c]) <= tol,
            format("%s: actionCenter.center[%d] expected the picked face's "
                   ~ "own centroid %.6f, got %.6f (tol %.1e) — did the live "
                   ~ "element pick (liveElementCenter) actually fire?",
                   cn, c, wantCentroid[c], got[c], tol));

    double dClick2 = 0;
    foreach (c; 0 .. 3) { double d = got[c] - wantNotClick[c]; dClick2 += d * d; }
    assert(dClick2 > 0.01,
        format("%s: actionCenter.center landed on/near the CLICK POINT "
               ~ "(dist^2=%.6f), not the face centroid — this would be the "
               ~ "userPin/click-point fallback tier, not liveElementCenter "
               ~ "(review finding R3)", cn, dClick2));

    playAndWait(upLog(cam, cpx, cpy));
    cmd("tool.set " ~ presetId ~ " off", cn);
}
