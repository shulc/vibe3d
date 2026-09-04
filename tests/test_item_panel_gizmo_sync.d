// Task 0614 Phase 5 — the numeric panel, the value bounds, and the guard
// against a click that misses the gizmo.
//
// Three separate properties, all end-to-end over HTTP:
//
//   1. R3 — an off-gizmo click in Item mode must not move the gizmo off the
//      item.  MEASURED FAILURE, not a hypothetical: before the guard, one
//      click in empty space with `move` armed pushed the published action
//      centre from the item's world pivot (1.55, 0.3, -0.3) to (-1.7905,
//      1.0466, 0) — wherever the click ray happened to meet the work plane —
//      because every bank reads an off-gizmo press in a relocate-PERMITTED
//      action-centre mode (Auto/None/Screen, the default) as a RELOCATE, and
//      the `userPlaced` pin it pushes OUTRANKS the item redirect in
//      ActionCenterStage.  Every later rotate/scale of that item then happens
//      about a point with no relation to it.
//
//      (The plan's R3 row predicted a different failure — the click promoting
//      the geometry type and silently turning the item tool into a vertex
//      tool.  That one is not reachable: `app.d`'s pick arm needs `dragMode`
//      to be a Select mode and `dragMode` only becomes one when NO tool is
//      active, and the interactive pick does not call the promote hook in any
//      case — only the selection COMMANDS do.  The selType assertion below is
//      kept anyway, cheap and directly on the property the row names.)
//
//   2. The panel and the gizmo show the same thing, in BOTH directions —
//      a panel write moves the gizmo, and a gizmo drag moves the panel value.
//
//   3. R7 layer two — a degenerate or absurd `scl` authored through the panel
//      is clamped, and the item's matrix stays finite and invertible.
//
// THE RIG.  `pos`, `rot`, `scl` and `pivot` are all displaced off every axis
// and the scale is non-uniform.  This is load-bearing, not decoration: at the
// origin with identity rotation and unit scale, "the centre stayed on the
// item" and "the centre fell back to the world origin" read the SAME numbers,
// and "restored the prior value" and "reset to the identity" do too.  Several
// specifications on this task have already been caught passing while checking
// nothing (see the plan's "Lessons"); a symmetric rig is how that happens.
//
// NOT TESTABLE HERE, on purpose — two things, so nobody adds a green that
// means nothing:
//   * The `transformGuard_` narrowing (a transform tool no longer greys the
//     transform rows under SelType.Item).  `paramEnabled` feeds the forms
//     renderer's greyed-row decision and nothing else; a `layer.attr` write is
//     a COMMAND and lands whether or not the row is greyed.  Pinned by a
//     unittest in source/layer_params.d instead.  What IS observable end to
//     end is the consequence — case 2 below writes through the panel's own
//     command WHILE the item tool is armed and watches the gizmo follow.
//   * The non-finite rejection.  A NaN cannot be delivered over the wire:
//     argstring's number scanner takes only `-?digits(.digits)?` so `NaN`
//     lexes as a bareword and `params._jsonFloat` answers 0.0f for it, and
//     JSON has no NaN literal.  Also pinned in source/layer_params.d.
//     Writing `layer.attr 0 scl.y NaN` here would land a 0.0, get floored,
//     and look exactly like a passing NaN test.

import http_client : testBaseUrl;
import std.net.curl;
import std.json;
import std.math  : fabs, isFinite;
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

JSONValue cmdJson(string body_) {
    auto j = parseJSON(cast(string)post(BASE ~ "/api/command", body_));
    assert(j["status"].str == "ok", "cmd `" ~ body_ ~ "` failed: " ~ j.toString);
    return j;
}

void script(string s) {
    auto j = parseJSON(cast(string)post(BASE ~ "/api/script", s));
    assert(j["status"].str == "ok", "script `" ~ s ~ "` failed: " ~ j.toString);
}

void resetCube() {
    auto j = parseJSON(cast(string)post(BASE ~ "/api/reset", ""));
    assert(j["status"].str == "ok", "/api/reset failed: " ~ j.toString);
    cmd(`{"id":"history.clear"}`);
}

bool approx(double a, double b, double eps = 1e-4) { return fabs(a - b) < eps; }

// ---- the rig ---------------------------------------------------------------
// Displaced, rotated off all three axes, non-uniform scale, pivot off-centre.
// World pivot = pos + pivot = (1.55, 0.30, -0.30); nothing about the rig makes
// that coincide with the world origin, the mesh centroid, or any single
// channel, so a wrong centre reads a different number whichever way it is
// wrong.
enum double RIG_PIVOT_X =  1.30 + 0.25;
enum double RIG_PIVOT_Y =  0.70 - 0.40;
enum double RIG_PIVOT_Z = -0.90 + 0.60;

void buildRig() {
    resetCube();
    cmd("layer.attr 0 pos.x 1.3");
    cmd("layer.attr 0 pos.y 0.7");
    cmd("layer.attr 0 pos.z -0.9");
    cmd("layer.attr 0 rot.x 20");
    cmd("layer.attr 0 rot.y 35");
    cmd("layer.attr 0 rot.z -50");
    cmd("layer.attr 0 scl.x 1.4");
    cmd("layer.attr 0 scl.y 0.8");
    cmd("layer.attr 0 scl.z 1.9");
    cmd("layer.attr 0 pivot.x 0.25");
    cmd("layer.attr 0 pivot.y -0.4");
    cmd("layer.attr 0 pivot.z 0.6");
    cmd("layer.select index:0");        // promotes SelType.Item to current
}

Vec3 publishedCentre() {
    auto ev = parseJSON(cast(string)get(BASE ~ "/api/toolpipe/eval"));
    auto c = ev["actionCenter"]["center"].array;
    return Vec3(cast(float)c[0].floating, cast(float)c[1].floating,
                cast(float)c[2].floating);
}

// The ACTIVE TOOL's own state — `{}` when no tool is armed (http_providers:
// `activeTool is null ? "{}"`). Distinct from `publishedCentre()` above in the
// way that matters for case 2: `/api/toolpipe/eval` builds its OWN
// SubjectPacket and never touches `activeTool`, so it answers identically with
// no tool at all.
JSONValue toolState() {
    return parseJSON(cast(string)get(BASE ~ "/api/tool/state"));
}

bool toolIsArmed() {
    auto st = toolState();
    return st.type == JSONType.object && ("pivot" in st) !is null;
}

// The GIZMO's own centre, straight off the tool (`moveGizmoCenter()`, the
// shared pose every enabled bank is posed to each frame) — NOT the pipeline's
// re-evaluated action centre. Asserts the tool is armed first, so "the tool was
// dropped" fails HERE with that diagnosis instead of surfacing later as a
// missing-key exception.
Vec3 gizmoCentre(string ctx) { return gizmoCentreFrom(toolState(), ctx); }

// Same read, but off a snapshot the CALLER already fetched — so a case that
// also wants `subject` can take both from ONE response instead of two GETs.
// The tool's resident fields are written across a frame (see case 2's
// preamble), so two GETs can straddle a phase boundary and report a
// self-contradicting pair; one GET cannot.
Vec3 gizmoCentreFrom(JSONValue st, string ctx) {
    assert(st.type == JSONType.object && ("pivot" in st) !is null,
        ctx ~ ": no tool is armed — /api/tool/state answered " ~ st.toString
      ~ ". Any assertion about the gizmo below would be about nothing.");
    auto p = st["pivot"].array;
    return Vec3(cast(float)p[0].floating, cast(float)p[1].floating,
                cast(float)p[2].floating);
}

// The tool's gizmo pose is written during the frame's update/draw, while a
// command applies on the main thread inside tickAll — measured to land in the
// same frame, but nothing in the contract PROMISES that ordering, and a loaded
// `-j 8` host is where an unpromised ordering stops holding. So poll, bounded,
// and hand back whatever the last read was: the CALLER asserts. A poll that
// times out therefore fails on the real value with the real message, never on a
// timeout that hides which number was wrong.
Vec3 gizmoCentreSettled(string ctx, Vec3 want, double eps = 1e-4) {
    import core.thread : Thread;
    import core.time   : dur;
    Vec3 got;
    foreach (_; 0 .. 40) {                 // 40 x 25 ms = 1 s ceiling
        got = gizmoCentre(ctx);
        if (approx(got.x, want.x, eps) && approx(got.y, want.y, eps)
         && approx(got.z, want.z, eps)) return got;
        Thread.sleep(dur!"msecs"(25));
    }
    return got;
}

// Read a layer attr back through the panel's OWN read path — the `?` query
// idiom the forms rows use to display a value (`layer.attr <i> <attr> ?`).
double readAttr(string attr, int index = 0) {
    auto body_ = "layer.attr " ~ index.to!string ~ " " ~ attr ~ " ?";
    auto j = parseJSON(cast(string)post(BASE ~ "/api/command", body_));
    assert(j["status"].str == "ok", "query `" ~ attr ~ "` failed: " ~ j.toString);
    assert("value" in j, "query response carries a value: " ~ j.toString);
    auto r = j["value"];
    if (r.type == JSONType.float_)   return r.floating;
    if (r.type == JSONType.integer)  return cast(double)r.integer;
    if (r.type == JSONType.uinteger) return cast(double)r.uinteger;
    assert(false, "unexpected value type for `" ~ attr ~ "`: " ~ j.toString);
}

// The layer's own record of a channel, straight off /api/layers — a SECOND,
// independent read path, so "panel agrees with the document" is a real
// comparison and not one field compared with itself.
double[3] layerChannel(string chan, int index = 0) {
    auto j = parseJSON(cast(string)get(BASE ~ "/api/layers"));
    auto a = j["layers"].array[index]["xform"][chan].array;
    return [a[0].floating, a[1].floating, a[2].floating];
}

double[16] layerMatrix(int index = 0) {
    auto j = parseJSON(cast(string)get(BASE ~ "/api/layers"));
    auto a = j["layers"].array[index]["xform"]["matrix"].array;
    double[16] m;
    foreach (i, v; a) m[i] = v.floating;
    return m;
}

string show(Vec3 v) { return format("(%.4f, %.4f, %.4f)", v.x, v.y, v.z); }

// Play one bare down+up at a pixel, with no motion between them.
void clickAt(int x, int y) {
    auto cam = fetchCamera();
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n"
      ~ `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n"
      ~ `{"t":100.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        cam.vpX, cam.vpY, cam.width, cam.height, x, y, x, y);
    playAndWait(log);
}

// -----------------------------------------------------------------------
// 1. R3 — an off-gizmo click must not drag the gizmo off the item.
//    Run for all three banks: the relocate lives in each bank's own
//    mouse-down, so a guard that only covered Move would leave two holes.
// -----------------------------------------------------------------------

unittest {
    foreach (tool; ["move", "rotate", "scale"]) {
        buildRig();
        script("tool.set " ~ tool);

        Vec3 before = publishedCentre();
        assert(approx(before.x, RIG_PIVOT_X) && approx(before.y, RIG_PIVOT_Y)
            && approx(before.z, RIG_PIVOT_Z),
            "precondition for `" ~ tool ~ "`: the item gizmo starts on the "
            ~ "item's world pivot (1.55, 0.30, -0.30) — without this the rest "
            ~ "of the case cannot tell a relocate from a no-op. Got "
            ~ show(before));

        // A pixel deep in the corner of the viewport: no gizmo handle, no
        // geometry — the definition of "missed the gizmo".
        auto cam = fetchCamera();
        clickAt(cam.vpX + 20, cam.vpY + 20);

        Vec3 after = publishedCentre();
        assert(approx(after.x, RIG_PIVOT_X) && approx(after.y, RIG_PIVOT_Y)
            && approx(after.z, RIG_PIVOT_Z),
            "an off-gizmo click in Item mode must leave the gizmo ON the item "
            ~ "(`" ~ tool ~ "`). It moved to " ~ show(after) ~ ". That is the "
            ~ "click-relocate: it pushes an ActionCenter userPlaced pin, which "
            ~ "outranks the item redirect, so the gizmo parks where the click "
            ~ "ray met the work plane and every later gesture pivots about a "
            ~ "point unrelated to the item.");

        // The property R3 names by its own title, checked directly.
        auto sel = parseJSON(cast(string)get(BASE ~ "/api/selection"));
        assert(sel["selType"].str == "item",
            "an off-gizmo click must not flip the current selection type out "
            ~ "of Item (`" ~ tool ~ "`), got " ~ sel["selType"].str);

        script("tool.set " ~ tool ~ " off");
    }
}

// -----------------------------------------------------------------------
// 1b. The guard must not eat a click that DID hit a handle. Without this,
//     "consume every off-gizmo down" and "consume every down" are the same
//     test, and the second one breaks the tool completely.
// -----------------------------------------------------------------------

unittest {
    buildRig();
    script("tool.set move");

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    Vec3 pivot = Vec3(cast(float)RIG_PIVOT_X, cast(float)RIG_PIVOT_Y,
                      cast(float)RIG_PIVOT_Z);
    int gx, gy; double ux, uy;
    axisGrabPx(pivot, vp, gx, gy, ux, uy);

    double preX = layerChannel("pos")[0];
    auto log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                            gx, gy,
                            gx + cast(int)(60.0 * ux), gy + cast(int)(60.0 * uy));
    playAndWait(log);
    script("tool.set move off");

    double postX = layerChannel("pos")[0];
    assert(!approx(postX, preX, 1e-3),
        "a drag that GRABBED the X arrow must still move the item — the "
        ~ "off-gizmo guard is scoped to `hitPart < 0` and must never swallow "
        ~ "a handle grab. pos.x stayed at " ~ postX.to!string);
}

// -----------------------------------------------------------------------
// 1c. The guard must not eat an off-gizmo drag in an action-centre mode
//     where the press RELOCATES NOTHING.
//
//     The guard exists to stop a press from pushing a `userPlaced` pin that
//     outranks the item redirect (case 1). That pin is pushed only in a
//     relocate-PERMITTED mode — `pressPlacesCenter()`, which is Auto,
//     None and Screen and nothing else. In every OTHER mode the same press
//     relocates nothing and still arms a drag from the stable pinned pivot:
//     move's `relocates == false` arm reaches `beginScreenPlaneDragAt(...,
//     notifyAcen=false)`, rotate's arms the arcball, scale's pinned `else`
//     branch calls `armPlaneDrag` unconditionally. Swallowing the press there
//     turns a legitimate drag into a NO-OP and buys nothing: there is no
//     relocate to prevent.
//
//     `actr.pivot` is used because it is the natural item-mode action centre
//     AND relocate-disallowed (Mode.Pivot == 10, outside the Auto/None/Screen
//     set), so this is a live regression rather than a corner case. It also
//     goes through `AxisStage.setUserMode` → `userLocked`, so the mode
//     survives anything that resets the transient pipe stages.
//
//     The item's own gizmo pivot is asserted UNCHANGED across the drag in the
//     sense that matters here: the centre tracks pos+pivot, so a relocate
//     would break that identity. Checking "it moved" alone would be satisfied
//     by a press that relocated and then dragged about the wrong point.
// -----------------------------------------------------------------------

unittest {
    buildRig();
    script("tool.set move");
    cmd("actr.pivot");

    Vec3 pinned = publishedCentre();
    assert(approx(pinned.x, RIG_PIVOT_X) && approx(pinned.y, RIG_PIVOT_Y)
        && approx(pinned.z, RIG_PIVOT_Z),
        "precondition: under `actr.pivot` the centre is the item's world "
        ~ "pivot (1.55, 0.30, -0.30), got " ~ show(pinned));

    auto cam = fetchCamera();
    // A corner pixel: no handle, no geometry — the same "missed the gizmo"
    // press case 1 fires, but now in a mode where it relocates nothing.
    int x0 = cam.vpX + 40, y0 = cam.vpY + 40;
    double[3] before = layerChannel("pos");
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x0 + 120, y0 + 40));
    double[3] after = layerChannel("pos");
    script("tool.set move off");

    assert(!approx(after[0], before[0], 1e-3)
        || !approx(after[1], before[1], 1e-3)
        || !approx(after[2], before[2], 1e-3),
        "an off-gizmo drag in a relocate-DISALLOWED mode (`actr.pivot`) must "
        ~ "still move the item: the press pins nothing, so there is nothing "
        ~ "for the Item-mode guard to protect and swallowing it makes the "
        ~ "drag a no-op. pos stayed at ("
        ~ after[0].to!string ~ ", " ~ after[1].to!string ~ ", "
        ~ after[2].to!string ~ ")");

    // The drag moved the item about its OWN pivot, not about a relocated
    // point: the centre still equals pos+pivot.
    Vec3 endCentre = publishedCentre();
    assert(approx(endCentre.x, after[0] + 0.25)
        && approx(endCentre.y, after[1] - 0.4)
        && approx(endCentre.z, after[2] + 0.6),
        "the action centre must still be the item's own world pivot after the "
        ~ "drag — if the press had relocated, it would sit wherever the click "
        ~ "ray met the work plane instead. Centre " ~ show(endCentre));
}

// -----------------------------------------------------------------------
// 2. Panel -> gizmo: a numeric write lands WHILE the item tool is armed,
//    the tool SURVIVES it, and the tool's own gizmo follows.
//
//    READ PATH, and why it is not `publishedCentre()`. This case used to
//    assert on /api/toolpipe/eval, which was inert: that provider builds its
//    OWN SubjectPacket and never references `activeTool`, so the assertion
//    held with `tool.set move` deleted AND with every line of the tool's item
//    support deleted. What it actually pinned was the action-centre stage's
//    item redirect tracking `pos` — a Phase 2 property with its own tests.
//    The tool's gizmo pose (/api/tool/state `pivot` == `moveGizmoCenter()`)
//    is the thing this case names, and it exists only while a tool is armed.
//
//    It is also the direct observable for the review's B1 fix: `layer.attr` is
//    a Model-class command, and app.d's dispatcher drops the armed tool for
//    Model commands outside the `tool.` / `scene.` / `file.` families. Before
//    B1 excluded `layer.attr` from that drop, the FIRST numeric edit in a row
//    Phase 5 had just un-greyed took the gizmo away with it.
// -----------------------------------------------------------------------

unittest {
    buildRig();
    script("tool.set move");

    // SETTLE, then read BOTH preconditions off ONE snapshot. Neither half is
    // decoration; both were MEASURED, by widening the two windows of the frame
    // that separate `tool.set` from the tool's resident state being current
    // (app.d: event drain → activeTool.update() → the whole ImGui section →
    // the FBO loop's activeTool.draw()). /api/tool/state is a DIRECT read of
    // those fields on the HTTP thread, so a reply can land inside either gap:
    //
    //   * arming .. update()  — the tool is armed but has never been ticked,
    //     so `pivot` is the fresh tool's un-posed (0,0,0). That is what the
    //     bounded poll below absorbs; it is the SAME hazard, and the same
    //     remedy, that `gizmoCentreSettled`'s own doc comment states — this
    //     read was simply the one post-`tool.set` read in this file that
    //     still read once and hoped.
    //   * update() .. draw()  — `pivot` is already on the item while
    //     `subject` still reads the freshly-constructed tool's default.
    //     THAT was the CI-only failure of this very assertion (run
    //     31246967466): the gizmo precondition passed and the subject
    //     precondition failed, on the line below it. Fixed in the PRODUCT
    //     (xfrm_transform.d's update() now refreshes the cached subject type
    //     alongside the gizmo pose, so the two can no longer disagree); the
    //     single-snapshot read here is what makes this case stop DEPENDING on
    //     that, because two separate GETs re-open the seam by construction.
    //
    // Nothing is weakened: the poll hands back the last value it saw and the
    // asserts below are the original ones, on the original numbers, with the
    // original messages — a genuinely wrong subject still fails, on the real
    // value, after at most a second.
    Vec3 wantPivot = Vec3(cast(float)RIG_PIVOT_X, cast(float)RIG_PIVOT_Y,
                          cast(float)RIG_PIVOT_Z);
    gizmoCentreSettled("precondition", wantPivot);
    auto st0 = toolState();
    Vec3 before = gizmoCentreFrom(st0, "precondition");
    assert(approx(before.x, RIG_PIVOT_X) && approx(before.y, RIG_PIVOT_Y)
        && approx(before.z, RIG_PIVOT_Z),
        "precondition: the tool's own gizmo starts on the item pivot "
        ~ "(1.55, 0.30, -0.30), got " ~ show(before));
    assert(st0["subject"].str == "item",
        "precondition: the tool's apply path is targeting the ITEM — without "
        ~ "this the case is about a vertex tool that happens to sit nearby. "
        ~ "Read from the SAME /api/tool/state snapshot as the gizmo centre "
        ~ "above, which is on the item — a disagreement between the two is "
        ~ "the tool's cached subject type going stale against its own gizmo "
        ~ "pose. /api/tool/state answered " ~ st0.toString);

    // 4.25 is chosen so pos.x + pivot.x = 4.50 differs from EVERY other number
    // in the rig — a gizmo that silently kept reading some other channel
    // cannot accidentally match it.
    cmd("layer.attr 0 pos.x 4.25");

    // B1, asserted before anything reads a value off the tool: a panel edit
    // CONTINUES the transform session.
    assert(toolIsArmed(),
        "a `layer.attr` write must not drop the armed transform tool — it "
        ~ "writes the very channels the tool is authoring, so it continues the "
        ~ "session exactly as a `tool.*` command does. /api/tool/state answered "
        ~ toolState().toString);

    assert(approx(readAttr("pos.x"), 4.25),
        "the panel's own read path must report the value it just wrote while "
        ~ "the item tool is armed, got " ~ readAttr("pos.x").to!string);
    assert(approx(layerChannel("pos")[0], 4.25),
        "and the document must agree with the panel");

    Vec3 want  = Vec3(cast(float)(4.25 + 0.25), cast(float)RIG_PIVOT_Y,
                      cast(float)RIG_PIVOT_Z);
    Vec3 after = gizmoCentreSettled("panel write", want);
    assert(approx(after.x, want.x) && approx(after.y, want.y)
        && approx(after.z, want.z),
        "the tool's OWN gizmo must follow a panel write to (4.50, 0.30, "
        ~ "-0.30) — a tool that cached the item pivot for the life of its "
        ~ "arming would still read " ~ show(before) ~ ". Got " ~ show(after));

    // The pipeline agrees with the tool. Kept as a SECOND, independent read
    // rather than the primary one: two sources reporting the same number is a
    // real comparison; the eval read alone is not a statement about the tool.
    Vec3 pipe = publishedCentre();
    assert(approx(pipe.x, after.x) && approx(pipe.y, after.y)
        && approx(pipe.z, after.z),
        "the pipeline's action centre and the tool's gizmo must be the same "
        ~ "point — tool " ~ show(after) ~ " vs pipeline " ~ show(pipe));

    script("tool.set move off");
}

// -----------------------------------------------------------------------
// 3. Gizmo -> panel: after a real drag, the panel's read path, the document
//    and the gizmo's own published centre all agree.
// -----------------------------------------------------------------------

unittest {
    buildRig();
    script("tool.set move");

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    Vec3 pivot = Vec3(cast(float)RIG_PIVOT_X, cast(float)RIG_PIVOT_Y,
                      cast(float)RIG_PIVOT_Z);
    int gx, gy; double ux, uy;
    axisGrabPx(pivot, vp, gx, gy, ux, uy);
    auto log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                            gx, gy,
                            gx + cast(int)(70.0 * ux), gy + cast(int)(70.0 * uy));
    playAndWait(log);

    double panelX = readAttr("pos.x");
    double docX   = layerChannel("pos")[0];
    assert(!approx(panelX, 1.3, 1e-3),
        "precondition: the drag actually moved the item off its authored 1.3 "
        ~ "— otherwise every agreement below is an agreement about nothing. "
        ~ "Got " ~ panelX.to!string);
    assert(approx(panelX, docX, 1e-6),
        "the panel's `?` read and /api/layers must report the same number to "
        ~ "the last digit either emits — panel " ~ panelX.to!string
        ~ " vs document " ~ docX.to!string);

    // The gizmo's own centre, derived ONLY from what the panel reports.
    Vec3 centre = publishedCentre();
    double expX = readAttr("pos.x") + readAttr("pivot.x");
    double expY = readAttr("pos.y") + readAttr("pivot.y");
    double expZ = readAttr("pos.z") + readAttr("pivot.z");
    assert(approx(centre.x, expX) && approx(centre.y, expY)
        && approx(centre.z, expZ),
        "after a drag the gizmo must sit at pos+pivot as the PANEL reports "
        ~ "them — expected " ~ format("(%.4f, %.4f, %.4f)", expX, expY, expZ)
        ~ ", gizmo at " ~ show(centre));

    script("tool.set move off");
}

// -----------------------------------------------------------------------
// 4. R7 layer two, over the wire: a degenerate or absurd scale authored
//    through the panel's command is clamped, and the item's matrix stays
//    finite and invertible.
// -----------------------------------------------------------------------

// det of the upper-left 3x3 of a column-major 4x4 — zero means the item
// transform has collapsed a dimension and cannot be inverted, which is what
// R7 is actually about.
double det3(double[16] m) {
    return m[0] * (m[5]*m[10] - m[6]*m[9])
         - m[4] * (m[1]*m[10] - m[2]*m[9])
         + m[8] * (m[1]*m[6]  - m[2]*m[5]);
}

unittest { // scl.x 0 — the degenerate band, through the argstring form the
           // forms panel itself dispatches.
    buildRig();
    cmd("layer.attr 0 scl.x 0");

    double sx = layerChannel("scl")[0];
    assert(sx > 0 && sx <= 1e-4 + 1e-9,
        "a zero scale must be floored to the positive floor 1e-4, got "
        ~ sx.to!string);
    // The other two channels are untouched — the clamp is per-component and
    // must not "normalise" the rest of the rig on its way past.
    assert(approx(layerChannel("scl")[1], 0.8) && approx(layerChannel("scl")[2], 1.9),
        "the floor touches only the component that went degenerate");

    auto m = layerMatrix();
    foreach (v; m) assert(isFinite(v), "no NaN/Inf in the composed matrix");
    assert(fabs(det3(m)) > 0.0,
        "the floored xform must still compose to an INVERTIBLE matrix");
}

unittest { // scl.y -1e-9 — the NEGATIVE side of the same band. A mirror is a
           // legal item transform, so the floor must keep the sign; an
           // implementation that clamped to +1e-4 would silently un-mirror.
    buildRig();
    cmdJson(`{"id":"layer.attr","_positional":[0,"scl.y",-1e-9]}`);

    double sy = layerChannel("scl")[1];
    assert(sy < 0,
        "a negative near-zero scale must stay NEGATIVE — the guard keeps the "
        ~ "matrix invertible, it does not decide whether the item is mirrored. "
        ~ "Got " ~ sy.to!string);
    assert(approx(sy, -1e-4, 1e-9),
        "and it lands exactly on the negative floor, got " ~ sy.to!string);
}

unittest { // scl.z 1e30 — the ceiling.
           //
           // Driven as a JSON positional ON PURPOSE. The argstring number
           // scanner (argstring.d parseNumber) has NO exponent rule: it reads
           // `1e30` as the integer 1 and leaves `e30` behind as a separate
           // bareword positional, so `layer.attr 0 scl.z 1e30` writes 1.0 and
           // a test written that way would pass with the ceiling deleted.
    buildRig();
    cmdJson(`{"id":"layer.attr","_positional":[0,"scl.z",1e30]}`);

    double sz = layerChannel("scl")[2];
    assert(approx(sz, 1e6, 1.0),
        "an absurd scale must be capped at the ceiling 1e6, got "
        ~ sz.to!string ~ " — uncapped it overflows to +inf at the first "
        ~ "matrix product, which is the very state the floor exists to "
        ~ "prevent");

    auto m = layerMatrix();
    foreach (v; m) assert(isFinite(v),
        "the capped xform composes to a finite matrix");
}

unittest { // the argstring exponent gap itself, pinned so the case above does
           // not look like belt-and-braces to a future reader.
    buildRig();
    cmd("layer.attr 0 scl.z 1e30");
    assert(approx(layerChannel("scl")[2], 1.0),
        "argstring has no exponent rule: `1e30` parses as the integer 1, so "
        ~ "this write lands 1.0. If this ever starts reading 1e6, the scanner "
        ~ "grew exponents and the JSON-positional case above can be simplified "
        ~ "— it is written the long way BECAUSE of this. Got "
        ~ layerChannel("scl")[2].to!string);
}
