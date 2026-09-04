// Task 0614 Phase 3 — the item apply path, Move bank.
//
// In Item mode, a Move gizmo drag must write the LAYER's `ItemXform.pos`,
// never `mesh.vertices`. This is the task's non-negotiable requirement
// (doc/item_mode_transform_plan.md): the mesh rides along with the item
// visually (composedMatrix() moves), but its LOCAL vertex coordinates stay
// byte-identical — checked here via an EXACT STRING COMPARE of
// /api/model?layer=0's response body, not an epsilon compare.
//
// Two cases: a REAL gizmo-arrow drag (drag_helpers, the actual interactive
// path a user drives) and a headless tool.attr/tool.doApply apply (the
// same applyTRS entry point, exercised without pixel hit-testing) — both
// must move the item and leave the mesh untouched.

import http_client : testBaseUrl;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.math  : fabs;
import std.conv  : to;
import std.format: format;

import drag_helpers;

void main() {}

alias BASE = testBaseUrl;

JSONValue cmd(string argstring) {
    auto j = parseJSON(cast(string)post(BASE ~ "/api/command", argstring));
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
    return j;
}

void resetCube() {
    auto j = parseJSON(cast(string)post(BASE ~ "/api/command", commandBody("scene.reset")));
    assert(j["status"].str == "ok", "/api/reset failed: " ~ j.toString);
    cmd(`{"id":"history.clear"}`);
}

bool approx(double a, double b, double eps = 1e-4) { return fabs(a - b) < eps; }

// The `vertices` array's own JSON text — NOT the whole /api/model response,
// which carries a fresh `"timestamp"` on every call and would poison an
// exact string compare regardless of whether the vertex data moved.
string verticesJson(int layer = 0) {
    auto j = parseJSON(cast(string)get(BASE ~ format("/api/model?layer=%d", layer)));
    return j["vertices"].toString();
}

Vec3 layerPos(int layer = 0) {
    auto j = parseJSON(cast(string)get(BASE ~ "/api/layers"));
    auto p = j["layers"].array[layer]["xform"]["pos"].array;
    return Vec3(cast(float)p[0].floating, cast(float)p[1].floating, cast(float)p[2].floating);
}

// -----------------------------------------------------------------------
// 1. A REAL gizmo-arrow drag on an item: pos.x moves, vertices untouched.
// -----------------------------------------------------------------------

unittest {
    resetCube();
    cmd("layer.select index:0");   // promotes SelType.Item to current

    auto sel = parseJSON(cast(string)get(BASE ~ "/api/selection"));
    assert(sel["selType"].str == "item", "layer.select must promote item to current");

    string preVerts = verticesJson(0);
    Vec3   prePos    = layerPos(0);
    assert(approx(prePos.x, 0) && approx(prePos.y, 0) && approx(prePos.z, 0),
        "sanity: fresh reset must have identity xform");

    post(BASE ~ "/api/script", "tool.set move");

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    Vec3 pivot = Vec3(0, 0, 0);   // the item's world pivot == pos+pivot == (0,0,0) here
    int gx, gy; double ux, uy;
    axisGrabPx(pivot, vp, gx, gy, ux, uy);
    int x1 = gx + cast(int)(60.0 * ux);
    int y1 = gy + cast(int)(60.0 * uy);

    auto log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height, gx, gy, x1, y1);
    playAndWait(log);

    post(BASE ~ "/api/script", "tool.set move off");

    Vec3 postPos = layerPos(0);
    assert(!approx(postPos.x, 0),
        "a real gizmo-arrow drag must actually move the item's pos.x — got "
        ~ postPos.x.to!string);
    assert(approx(postPos.y, prePos.y) && approx(postPos.z, prePos.z),
        "an X-arrow drag must not perturb Y/Z");

    string postVerts = verticesJson(0);
    assert(preVerts == postVerts,
        "a drag must move the ITEM and leave local vertex coordinates "
        ~ "BYTE-IDENTICAL — /api/model?layer=0 changed after a Move drag "
        ~ "(the apply path wrote mesh.vertices instead of, or in addition "
        ~ "to, layer.xform.pos)");
}

// -----------------------------------------------------------------------
// 2. Headless tool.attr/tool.doApply — the SAME applyTRS entry point, an
//    exact known delta so the moved amount can be asserted precisely.
// -----------------------------------------------------------------------

unittest {
    resetCube();
    cmd("layer.attr 0 pos.x 1.0");
    cmd("layer.attr 0 pivot.z -0.5");
    cmd("layer.select index:0");

    string preVerts = verticesJson(0);

    cmd("tool.set move on");
    cmd("tool.attr move TX 2.5");
    cmd("tool.doApply");
    cmd("tool.set move off");

    Vec3 postPos = layerPos(0);
    assert(approx(postPos.x, 3.5, 1e-3),
        "headless TX 2.5 on pos.x=1.0 must land at 3.5, got " ~ postPos.x.to!string);
    assert(approx(postPos.y, 0, 1e-3) && approx(postPos.z, 0, 1e-3),
        "TX must not perturb Y/Z, got y=" ~ postPos.y.to!string
        ~ " z=" ~ postPos.z.to!string);

    string postVerts = verticesJson(0);
    assert(preVerts == postVerts,
        "headless move apply must leave mesh.vertices byte-identical (rot/scl "
        ~ "untouched too, since only TX was set) — /api/model?layer=0 changed");
}

// -----------------------------------------------------------------------
// 3. S4 (0614 review) — two headless applies of the SAME unchanged tool.attr
//    are IDEMPOTENT for an item subject, but ACCUMULATE for a vertex one.
//    Same entry point (tool.doApply), two different behaviours by subject
//    type — measured, not designed, and pinned here so a macro that
//    replays "set TX; doApply; doApply" does not discover the divergence
//    the hard way.
//
//    Vertex mode: applyHeadless() hands applyTRS a FRESH mesh.vertices.dup
//    baseline on EVERY call (no run tracking at all for the headless path),
//    so a second call re-applies TX onto the ALREADY-moved mesh — the net
//    effect accumulates (2x).
//
//    Item mode: restoreItemBaseline()'s `itemBaselineValid` flag, once set
//    by the FIRST call, stays true across a SECOND call with no boundary
//    in between (no selection/mutation-change tick occurs between two bare
//    HTTP tool.doApply calls) — so the second call restores the item's
//    xform back to the cached itemDragBaseline (undoing the first call's
//    write) before re-applying the SAME run.t — net effect is idempotent
//    (1x), matching a live-drag's per-frame re-evaluate semantics rather
//    than the headless one-shot contract vertex mode follows.
//
//    Chose to PIN rather than align: aligning would mean giving item mode's
//    headless path some way to tell "this itemBaselineValid was set by a
//    REAL run (beginRunGesture) — keep restoring" apart from "this was set
//    by the headless fallback capture — go fresh next call", and that
//    distinction touches the SAME frozen-frame/run-baseline discipline the
//    review confirmed is otherwise correct (REVIEW-1 / R15) — not a change
//    to make inside a review-fix pass. Left as a named, deliberate
//    divergence rather than silently "fixed" one way or the other.
// -----------------------------------------------------------------------

unittest {
    resetCube();
    cmd("layer.select index:0");

    Vec3 prePos = layerPos(0);

    cmd("tool.set move on");
    cmd("tool.attr move TX 2.5");
    cmd("tool.doApply");
    Vec3 afterFirst = layerPos(0);
    cmd("tool.doApply");   // SAME attrs, no change in between
    Vec3 afterSecond = layerPos(0);
    cmd("tool.set move off");

    assert(approx(afterFirst.x, prePos.x + 2.5, 1e-3),
        "sanity: the first apply must move pos.x by exactly TX — got "
        ~ afterFirst.x.to!string);
    assert(approx(afterSecond.x, afterFirst.x, 1e-3),
        "PINNED (S4, 0614 review): a second identical tool.doApply in item "
        ~ "mode must be IDEMPOTENT (land at the SAME pos.x as the first "
        ~ "apply, not accumulate to prePos+5.0) — before=" ~ prePos.x.to!string
        ~ " afterFirst=" ~ afterFirst.x.to!string
        ~ " afterSecond=" ~ afterSecond.x.to!string);
    // The discriminating wrong answer: an accumulating (vertex-mode-style)
    // item apply would land here instead.
    assert(!approx(afterSecond.x, prePos.x + 5.0, 1e-3),
        "the second apply must NOT have accumulated a second TX — that "
        ~ "would be the vertex-mode behaviour, not the item-mode one");
}
