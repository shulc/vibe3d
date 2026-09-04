// Task 0614 Phase 3 — the anti-drift proof, and the strongest single check
// in this task: the item drag obeys the SAME LAW as the vertex drag (frozen
// frame, the star de-rotation, fold order), not a parallel re-implementation
// that happens to agree on paper.
//
// Method: the SAME gesture is applied twice — once against a VERTEX subject
// (selection empty ⇒ whole mesh, mesh.selectedVertexIndicesVertices'
// documented fallback), once against an ITEM subject on a FRESH identical
// cube. Assert `itemMatrix . baseVertex ~= vertexDraggedPosition` for every
// vertex.
//
// Single-bank and T+S cases drive the gesture via tool.attr + tool.doApply
// (the headless entry point, which funnels through the identical applyTRS
// this task's drag path uses per doc/item_mode_transform_plan.md §(b)). T+R
// composition specifically needs a REAL DRAG instead — see the comment at
// checkComposedParityDrag for why: the vertex fold's translate-term
// de-rotation is gated on `activeDrag is moveSub` and simply does not fire
// for a headless call, so a headless T+R reproduction is not testing the
// same law a drag exercises.
//
// R16 (the vacuity hazard): the two runs do NOT share a centre by default
// (vertex ⇒ selection centroid, item ⇒ item world pivot) — pinned here via
// `actr.origin` in BOTH runs, which the plan's Q3 table marks
// "unchanged (subject-independent)" for item mode, so it reads the SAME
// world origin regardless of subject.
//
// The rig's IDENTITY ItemXform is LOAD-BEARING (L4): the item-scale law
// (same-index) and the vertex-scale law (geometric, along frame axes) only
// coincide when the item's own axes ARE the frame axes — true at rot=0,
// false on a rotated base. Do NOT "generalise" this rig to a rotated base;
// the same-index rule has its own dedicated test
// (test_item_scale_same_index.d).
//
// R+S composed in one run is explicitly EXCLUDED (not a "known-bad" case —
// UNMEASURED; phase0b_findings.md's own "Still not measured about scale"
// list names this gap).

import http_client : testBaseUrl;
import std.net.curl;
import std.json;
import std.math  : fabs;
import std.conv  : to;
import std.format: format;

import drag_helpers;

alias BASE = testBaseUrl;

void main() {}

JSONValue cmd(string argstring) {
    auto j = parseJSON(cast(string)post(BASE ~ "/api/command", argstring));
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
    return j;
}

void resetCube() {
    auto j = parseJSON(cast(string)post(BASE ~ "/api/reset", ""));
    assert(j["status"].str == "ok", "/api/reset failed: " ~ j.toString);
    cmd(`{"id":"history.clear"}`);
}

bool approx(double a, double b, double eps = 1e-4) { return fabs(a - b) < eps; }

double[3][] fetchVerts() {
    auto arr = parseJSON(cast(string)get(BASE ~ "/api/model"))["vertices"].array;
    double[3][] out_;
    out_.length = arr.length;
    foreach (i, v; arr) {
        auto a = v.array;
        out_[i] = [a[0].floating, a[1].floating, a[2].floating];
    }
    return out_;
}

double[16] fetchLayerMatrix(int layer = 0) {
    auto j = parseJSON(cast(string)get(BASE ~ "/api/layers"));
    auto m = j["layers"].array[layer]["xform"]["matrix"].array;
    double[16] out_;
    foreach (i; 0 .. 16) out_[i] = m[i].floating;
    return out_;
}

double[3] applyMatrix(const double[16] m, double[3] p) {
    return [
        m[0]*p[0] + m[4]*p[1] + m[8] *p[2] + m[12],
        m[1]*p[0] + m[5]*p[1] + m[9] *p[2] + m[13],
        m[2]*p[0] + m[6]*p[1] + m[10]*p[2] + m[14],
    ];
}

// Applies one gesture through the headless tool.attr/tool.doApply path — the
// SAME applyTRS entry point a real drag uses. `bank` is "move"/"rotate"/
// "scale"; `attr`/`val` is the ONE numeric channel driven (TX/RY/SX etc.),
// or a list of (attr,val) pairs for a composed gesture in ONE run.
void applyGesture(string bank, string[][] attrVals) {
    cmd("tool.set " ~ bank ~ " on");
    foreach (av; attrVals)
        cmd("tool.attr " ~ bank ~ " " ~ av[0] ~ " " ~ av[1]);
    cmd("tool.doApply");
    cmd("tool.set " ~ bank ~ " off");
}

// Runs `attrVals` (one composed gesture) against a VERTEX subject on a fresh
// cube and returns the resulting vertex positions.
double[3][] runVertexCase(string bank, string[][] attrVals) {
    resetCube();
    cmd("actr.origin");   // R16 — pin the centre; vertex-mode default here
                           // would otherwise be the selection/geometry centroid.
    applyGesture(bank, attrVals);
    return fetchVerts();
}

// Runs the SAME `attrVals` against an ITEM subject on a fresh cube and
// returns the composed item matrix + the PRE-gesture (base) vertex
// positions (identical to the vertex case's pre-gesture cube, since both
// start from the same /api/reset).
void runItemCase(string bank, string[][] attrVals,
                  out double[16] matrix, out double[3][] baseVerts)
{
    resetCube();
    cmd("actr.origin");   // R16 — the SAME pin, so both runs share one centre.
    baseVerts = fetchVerts();
    cmd("layer.select index:0");   // promotes SelType.Item to current
    applyGesture(bank, attrVals);
    matrix = fetchLayerMatrix(0);
}

void checkParity(string label, string bank, string[][] attrVals, double tol = 1e-4) {
    auto vertexResult = runVertexCase(bank, attrVals);

    double[16] matrix;
    double[3][] baseVerts;
    runItemCase(bank, attrVals, matrix, baseVerts);

    assert(baseVerts.length == vertexResult.length,
        label ~ ": vertex count mismatch between the two runs");

    foreach (i; 0 .. baseVerts.length) {
        auto predicted = applyMatrix(matrix, baseVerts[i]);
        auto actual    = vertexResult[i];
        assert(approx(predicted[0], actual[0], tol)
            && approx(predicted[1], actual[1], tol)
            && approx(predicted[2], actual[2], tol),
            format("%s: vertex %d — itemMatrix*baseVertex=(%.6f,%.6f,%.6f) but "
                 ~ "the vertex-mode drag landed at (%.6f,%.6f,%.6f)",
                   label, i, predicted[0], predicted[1], predicted[2],
                   actual[0], actual[1], actual[2]));
    }
}

unittest { checkParity("pure T",        "move",   [["TX", "1.3"]]); }
unittest { checkParity("pure R",        "rotate", [["RY", "35"]]); }
unittest { checkParity("uniform S",     "scale",  [["SX", "1.7"], ["SY", "1.7"], ["SZ", "1.7"]]); }
unittest { checkParity("non-uniform S", "scale",  [["SX", "2.0"], ["SY", "0.5"]]); }
// R+S in one run is EXCLUDED — see the file header. T+R and T+S below drive
// the "move" bank with a HELD rotate/scale from a prior gesture in the SAME
// activation (two applyGesture calls before the shared assertion), proving
// the composed-run fold (not just a single-bank gesture) obeys the same law.

// A genuinely COMPOSED run needs ONE tool INSTANCE with all three banks
// live — "move"/"rotate"/"scale" are three SEPARATE registered
// XfrmTransformTool instances (each with only one flag set), so switching
// `tool.set move` -> `tool.set rotate` deactivates one and activates a
// DIFFERENT object, which is two independent one-bank runs, not a composed
// one. "xfrm.transform" is the one registered id with T/R/S all enabled
// (XfrmTransformTool's own field defaults, registration.d).
//
// A SINGLE tool.doApply, not two: applyHeadless() (xfrm_transform.d) hands
// applyTRS a FRESH `mesh.vertices.dup` baseline on EVERY call and never
// resets `run.t`/`headlessRotate` between calls — that models a live drag's
// per-frame re-evaluate against ONE run-start dragBaseline, but only when
// the SAME gesture's values are set before ONE apply. TWO separate
// tool.doApply calls instead double-applies the held translate (baseline
// 2 is already-T-shifted, and run.t is unchanged, so T lands twice) — that
// is a headless-path artefact, not a composed-run law, so this helper sets
// BOTH attrs before the one doApply that actually represents "T and R both
// held in one gesture". Valid for T+S (no rotation involved, so no
// de-rotation gate to trip) — see the T+R note below for why that pairing
// needs a different mechanism.
void applyComposed(string[][] firstAttrs, string[][] secondAttrs)
{
    cmd("tool.set xfrm.transform on");
    foreach (av; firstAttrs)  cmd("tool.attr xfrm.transform " ~ av[0] ~ " " ~ av[1]);
    foreach (av; secondAttrs) cmd("tool.attr xfrm.transform " ~ av[0] ~ " " ~ av[1]);
    cmd("tool.doApply");
    cmd("tool.set xfrm.transform off");
}

void checkComposedParity(string label,
                          string[][] firstAttrs, string[][] secondAttrs,
                          double tol = 1e-4)
{
    resetCube();
    cmd("actr.origin");
    applyComposed(firstAttrs, secondAttrs);
    auto vertexResult = fetchVerts();

    resetCube();
    cmd("actr.origin");
    auto baseVerts = fetchVerts();
    cmd("layer.select index:0");
    applyComposed(firstAttrs, secondAttrs);
    auto matrix = fetchLayerMatrix(0);

    foreach (i; 0 .. baseVerts.length) {
        auto predicted = applyMatrix(matrix, baseVerts[i]);
        auto actual    = vertexResult[i];
        assert(approx(predicted[0], actual[0], tol)
            && approx(predicted[1], actual[1], tol)
            && approx(predicted[2], actual[2], tol),
            format("%s: vertex %d — itemMatrix*baseVertex=(%.6f,%.6f,%.6f) but "
                 ~ "the vertex-mode drag landed at (%.6f,%.6f,%.6f)",
                   label, i, predicted[0], predicted[1], predicted[2],
                   actual[0], actual[1], actual[2]));
    }
}

unittest {
    checkComposedParity("T+S in one run", [["TX", "1.0"]], [["SX", "2.0"]]);
}

// -----------------------------------------------------------------------
// T+R composition needs a REAL DRAG, not tool.doApply. The vertex fold's
// TRANSLATE-TERM DE-ROTATION (xfrm_transform.d's invariant *) is gated on
// `activeDrag is moveSub` — it exists ONLY for a live gizmo drag; the
// comment there says so explicitly: "In the panel/headless path ... run.t
// is a direct panel value ... M = run.r . T(worldDelta) which is the
// correct T-before-R chain semantics for numeric TX/RY attrs" — i.e. a
// headless T+R composes WITHOUT de-rotation (translate gets rotated too),
// while a REAL DRAG composes WITH it (translate stays world-aligned
// regardless of the held rotation). This item kernel always de-rotates
// (matching the DRAG convention, per doc/item_mode_transform_plan.md
// §(c)) — so comparing it against a HEADLESS vertex run picks the WRONG
// reference and fails for a reason that has nothing to do with the law
// under test (confirmed empirically while writing this file: a headless
// T+R run lands at a measurably different point than a dragged one). Both
// runs below therefore use two REAL drags in one activation instead.
// -----------------------------------------------------------------------

void dragMoveXOnce(Viewport vp, int pixels) {
    Vec3 pivot = Vec3(0, 0, 0);   // identity xform in both runs here
    int gx, gy; double ux, uy;
    axisGrabPx(pivot, vp, gx, gy, ux, uy);
    int x1 = gx + cast(int)(pixels * ux);
    int y1 = gy + cast(int)(pixels * uy);
    playAndWait(buildDragLog(vp.x, vp.y, vp.width, vp.height, gx, gy, x1, y1));
}

// X-ring grab (normal +X, YZ plane), the same 110-degree point
// test_far_pivot_fold.d's ringGrabPx uses — a purely vertical drag there is
// mostly tangential, producing a real, non-trivial rotation about world X.
void dragRotateXOnce(Viewport vp, int pixelsY) {
    import std.math : PI, sin, cos;
    Vec3 pivot = Vec3(0, 0, 0);
    float size = gizmoSize(pivot, vp);
    float a = 110.0f * cast(float)PI / 180.0f;
    Vec3 p = Vec3(pivot.x, pivot.y + cos(a) * size, pivot.z + sin(a) * size);
    float sx, sy;
    projectToWindow(p, vp, sx, sy);
    int gx = cast(int)sx, gy = cast(int)sy;
    playAndWait(buildDragLog(vp.x, vp.y, vp.width, vp.height, gx, gy, gx, gy + pixelsY));
}

void checkComposedParityDrag(string label, void delegate(Viewport) gestures,
                              double tol = 5e-3)
{
    resetCube();
    cmd("actr.origin");
    post(BASE ~ "/api/script", "tool.set xfrm.transform");
    { auto cam = fetchCamera(); gestures(viewportFromCamera(cam)); }
    post(BASE ~ "/api/script", "tool.set xfrm.transform off");
    auto vertexResult = fetchVerts();

    resetCube();
    cmd("actr.origin");
    auto baseVerts = fetchVerts();
    cmd("layer.select index:0");
    post(BASE ~ "/api/script", "tool.set xfrm.transform");
    { auto cam = fetchCamera(); gestures(viewportFromCamera(cam)); }
    post(BASE ~ "/api/script", "tool.set xfrm.transform off");
    auto matrix = fetchLayerMatrix(0);

    foreach (i; 0 .. baseVerts.length) {
        auto predicted = applyMatrix(matrix, baseVerts[i]);
        auto actual    = vertexResult[i];
        assert(approx(predicted[0], actual[0], tol)
            && approx(predicted[1], actual[1], tol)
            && approx(predicted[2], actual[2], tol),
            format("%s: vertex %d — itemMatrix*baseVertex=(%.6f,%.6f,%.6f) but "
                 ~ "the vertex-mode drag landed at (%.6f,%.6f,%.6f)",
                   label, i, predicted[0], predicted[1], predicted[2],
                   actual[0], actual[1], actual[2]));
    }
}

unittest {
    checkComposedParityDrag("T+R in one run", (Viewport vp) {
        dragMoveXOnce(vp, 40);
        dragRotateXOnce(vp, 80);
    });
}
unittest {
    // The case objection 1 named: rotate-then-move in one run must NOT
    // re-rotate the translate (the star de-rotation) — this is the ONE case
    // that is meaningless without a real drag, since the de-rotation gate
    // this is proving is drag-only by construction.
    checkComposedParityDrag("rotate-then-move in one run", (Viewport vp) {
        dragRotateXOnce(vp, 80);
        dragMoveXOnce(vp, 40);
    });
}
