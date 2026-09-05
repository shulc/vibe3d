// Task 0612 Stage 8 — the item transform binds the FOCUSED item, and the
// moving set is narrowed around it (plan §7.1 + §7.2, approximation D).
//
// WHAT WAS WRONG BEFORE THIS STAGE, and why it needed a mesh-less item to
// become visible. `Document` splits two roles: `primary` is the MESH edit
// target (a kind that cannot hold a mesh can never be one) and `focusedItem`
// is the item-selection focus (any kind). On an all-mesh document every
// selection route keeps them equal. The gizmo centre, the item basis and the
// moving set were all wired to `primary`; the properties form followed
// `focusedItem`. So selecting a reference-image plane put the gizmo on the
// MESH's pivot while the panel showed the plane's numbers, and a drag moved
// the mesh along with the plane.
//
// THE APPROXIMATION, NAMED. `Document`'s invariant forces the mesh edit
// target to stay selected, so "the plane alone" is not a representable
// selection — the set is `{plane, mesh}`. The measured reference has no such
// problem to patch: its edit target is a latched reference that is not a
// member of the item selection. We approximate that observable by SUBTRACTING
// the forced member (drop `primary` from the moving set when it is not the
// transform target) rather than by unlatching the pointer, which re-decides
// `Document.background()` and is a task of its own. T-X6 below asserts the
// one place the approximation and the reference disagree — it is the
// acceptance test that follow-up task inherits, and it flips deliberately.
//
// WHY EVERY FIXTURE HERE PUTS THE PLANE AT A NON-IDENTITY, NON-MESH POSE.
// The cube `/api/reset` gives us sits at the origin with an identity xform.
// A plane left at identity would read the SAME pivot as the mesh, so an
// implementation that still binds `primary` would report the right number for
// the wrong reason and T-X1 could not fail. Every pose below is chosen so the
// two candidate answers are different in all three components.

import http_client : testBaseUrl, getJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.math   : fabs;
import std.conv   : to;
import std.format : format;

import drag_helpers;

void main() {}

alias BASE = testBaseUrl;


JSONValue cmd(string argstring) {
    auto j = parseJSON(cast(string) post(BASE ~ "/api/command", argstring));
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
    return j;
}

void resetCube() {
    auto j = parseJSON(cast(string) post(BASE ~ "/api/command", commandBody("scene.reset")));
    assert(j["status"].str == "ok", "/api/reset failed: " ~ j.toString);
    cmd(`{"id":"history.clear"}`);
}

bool approx(double a, double b, double eps = 1e-4) { return fabs(a - b) < eps; }

JSONValue layers()             { return getJson("/api/layers")["layers"]; }
JSONValue layerAt(size_t i)    { return layers().array[i]; }
/// The layer's whole `xform` object as TEXT — the byte-identical probe. An
/// epsilon compare would hide a sub-epsilon drag; this cannot.
string    xformText(size_t i)  { return layerAt(i)["xform"].toString; }
double    posX(size_t i)       { return layerAt(i)["xform"]["pos"].array[0].floating; }
bool      isXTarget(size_t i)  { return layerAt(i)["transformTarget"].boolean; }
JSONValue history()            { return getJson("/api/history"); }

JSONValue doUndo() { return parseJSON(cast(string) post(BASE ~ "/api/command", commandBody("history.undo"))); }

/// ONE read of the armed transform tool's own state dump — no polling.
///
/// THE PRECONDITION IS THE PART THAT CHANGED (task 1670, side finding 2). It
/// used to be `assert("pivot" in st)`, standing in for "the transform tool is
/// armed". That stopped being true at task 1610, when the edge-extend tool's
/// own `toolStateJson` began publishing a `pivot` too: a key that two different
/// tools emit says nothing about WHICH tool answered, so all the check still
/// ruled out was `{}` — the no-tool reply — and every real arming of the
/// WRONG tool passed it. It had become a claim about the reply's shape rather
/// than about the app's state.
///
/// What discriminates is the dump's own `tool` tag: `XfrmTransformTool` is the
/// sole writer of `"xfrm"` (grep `root["tool"]` across source/tools — eleven
/// tools, eleven distinct names). `enabled.t` is the second half, and it is
/// not decoration: `pivot` is `moveGizmoCenter()`, the MOVE bank's handler
/// centre, so a preset that armed R/S with T off would publish a `pivot` this
/// file's numbers are not about. Every caller here arms `move`, so both are
/// real claims.
JSONValue toolState() {
    auto st = getJson("/api/tool/state");
    assert("tool" in st && st["tool"].str == "xfrm",
        "the TRANSFORM tool must be the armed one — `/api/tool/state` answers "
        ~ "`{}` with no tool at all and its own name with any other, and "
        ~ "since task 1610 the presence of a `pivot` key no longer tells "
        ~ "those cases apart. got " ~ st.toString);
    assert("enabled" in st && st["enabled"]["t"].boolean,
        "…and its MOVE bank must be on, because `pivot` IS the move bank's "
        ~ "handler centre (`moveGizmoCenter()`). got " ~ st.toString);
    return st;
}

/// The shared gizmo centre the tool publishes — `ActionCenterStage`'s answer,
/// read through the tool rather than inferred from a drag.
double[3] pivotOf(JSONValue st) {
    auto p = st["pivot"].array;
    return [p[0].floating, p[1].floating, p[2].floating];
}

/// The same centre, read through the PIPE instead of through the tool. Two
/// independent channels onto one quantity, which is what makes T-X7 below an
/// assertion about agreement rather than about a number.
double[3] actionCentre() {
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return [c[0].floating, c[1].floating, c[2].floating];
}

/// The gizmo centre with a BOUNDED SETTLE — at most 1 s, 40 x 25 ms, the same
/// shape as `gizmoCentreSettled` in tests/test_item_panel_gizmo_sync.d.
///
/// WHY THIS IS THE SECOND LAYER AND NOT THE FIX (task 1670). `/api/tool/state`
/// is answered straight off the HTTP thread from the tool's resident fields,
/// so a read issued the instant after `tool.set` returns can land before the
/// frame loop has ticked the tool. That is a PRODUCT hazard, it was fixed in
/// the product (the prepared arm poses the fresh tool before it returns —
/// `PreparedToolPoseDoorClient.prepareDoorInitialPose`, called from
/// `prepareArm`; task 1670's `armedToolPoseHook` did this until 4053 deleted
/// it with the legacy arm branch), and a settle alone would have hidden it:
/// the poll would simply have waited out the wrong answer and gone green over
/// a race every other consumer of
/// that route still had. The sibling fix on 2026-08-08 landed both halves for
/// the same reason, and this is the matching pair.
///
/// So the settle earns its place only as insurance against the OTHER sources
/// of staleness on this route (a command whose effect needs a main-loop pass),
/// and it is deliberately NOT used by T-X7, whose whole subject is the value
/// at the instant of arming. Nothing is weakened here either: the poll hands
/// back the last value it saw and the caller's own assertion, on the caller's
/// own numbers, still runs on it.
double[3] toolPivot(double[3] want, double eps = 1e-4) {
    import core.thread : Thread;
    import core.time   : dur;
    double[3] got;
    foreach (_; 0 .. 40) {                 // 40 x 25 ms = 1 s ceiling
        got = pivotOf(toolState());
        if (approx(got[0], want[0], eps) && approx(got[1], want[1], eps)
         && approx(got[2], want[2], eps)) return got;
        Thread.sleep(dur!"msecs"(25));
    }
    return got;
}

/// One headless Move gesture of `dx` along X, opened and CLOSED (the tool
/// drop is the run boundary the undo granularity is measured against).
void moveX(double dx) {
    cmd("tool.set move on");
    cmd(format("tool.attr move TX %.6f", dx));
    cmd("tool.doApply");
    cmd("tool.set move off");
}

/// Fixture: the cube at layer 0 (primary, identity) plus one reference-image
/// plane at layer 1, posed so its world pivot shares no component with the
/// cube's, with BOTH selected and the plane holding the focus.
///
/// TASK 0668 CHANGED HOW THIS STATE IS REACHED, and the change is the point of
/// the file. It used to be `layer.select index:1 mode:set` — an exclusive
/// select that the document turned into `{plane, mesh}` by FORCING the mesh to
/// stay selected, because the invariants had nowhere else to put the edit
/// target. 0668 removed that forcing: an exclusive select of a plane now
/// leaves `{plane}` and no edit target at all, which needs no narrowing.
///
/// The state approximation D exists for is the OTHER order — select the mesh,
/// then ctrl-ADD the plane — where the mesh is in the selection because the
/// USER put it there. That is what this fixture builds now, and it is exactly
/// the divergence T-X6 declares.
void planeFixture() {
    resetCube();
    cmd(`{"id":"imagePlane.add","params":{"name":"Ref","projection":"front"}}`);
    assert(layers().array.length == 2, "fixture: cube + plane");
    assert(layerAt(1)["type"].str == "imagePlane", "fixture: layer 1 is the plane");
    cmd("layer.attr 1 pos.x 4.0");
    cmd("layer.attr 1 pos.y 1.5");
    cmd("layer.attr 1 pos.z -2.0");
    cmd("layer.attr 1 pivot.x 0.25");
    cmd("layer.select index:0 mode:set");
    cmd("layer.select index:1 mode:add");
    // Vacuity guards. Without these, every assertion below could be passing
    // on a document that simply does not hold the state it claims to.
    assert(layerAt(0)["primary"].boolean,
        "vacuity: the MESH is still the mesh edit target — a plane can never "
        ~ "be one, and if it could there would be nothing to narrow");
    assert(layerAt(0)["selected"].boolean,
        "vacuity: the mesh is in the SET, put there by the select above. If "
        ~ "this ever reads false the approximation this file tests has become "
        ~ "unnecessary on this path too");
    assert(layerAt(1)["focused"].boolean, "vacuity: the plane holds the focus");
    assert(getJson("/api/selection")["selType"].str == "item",
        "vacuity: selecting a layer promotes the item selection type, which "
        ~ "is what routes the gesture to the item branch at all");
}

// ---------------------------------------------------------------------------
// T-X1 — the gizmo centre follows the FOCUS, not the primary.
//
// Wrong implementation: `ActionCenterStage`'s `primarySrc_` left wired to
// `document.primary` (what it was until this stage). It reads the CUBE's
// world pivot, (0,0,0), where the correct answer is the plane's (4.25, 1.5,
// -2). All three components differ, so no single-axis coincidence can hide it.
//
// TASK 1670 CORRECTED WHAT A ZERO HERE MEANS, and the message below carries
// the correction because this row's failure text is the first thing the next
// reader sees. The row still pins the binding; it is no longer the ONLY thing
// a zero can mean, and the accusation the message used to make on its own was
// measured false.
// ---------------------------------------------------------------------------
unittest {
    planeFixture();
    cmd("tool.set move on");
    scope (exit) cmd("tool.set move off");

    auto piv = toolPivot([4.25, 1.5, -2.0]);
    assert(approx(piv[0], 4.25) && approx(piv[1], 1.5) && approx(piv[2], -2.0),
        format("T-X1: the gizmo centre must be the FOCUSED item's world pivot "
             ~ "(pos + pivot = 4.25, 1.5, -2), got (%.4f, %.4f, %.4f).\n"
             ~ "  READ THIS BEFORE HUNTING A BINDING. A zero here does NOT by "
             ~ "itself mean `ActionCenterStage.primarySrc_` is back on "
             ~ "`document.primary`; that is one cause, and it is the one this "
             ~ "row was written for, but it is not what a zero meant the last "
             ~ "time this fired. Measured on task 1670: in the same instant "
             ~ "/api/toolpipe/eval reported the CORRECT centre and this very "
             ~ "snapshot carried subject:\"component\" — a freshly built tool's "
             ~ "constructor defaults, in both fields at once. The stage was "
             ~ "right the whole way through.\n"
             ~ "  So check WHICH of the two it is, and check it with the "
             ~ "action centre: if /api/toolpipe/eval also reports (0,0,0), the "
             ~ "binding is the suspect; if it reports the plane's pivot while "
             ~ "this reads zero, the tool was READ BEFORE ITS FIRST TICK. "
             ~ "Every `tool.set` builds a NEW tool whose pose starts at the "
             ~ "origin, and the prepared arm's initial-pose door — "
             ~ "`PreparedToolPoseDoorClient.prepareDoorInitialPose`, called "
             ~ "from `prepareArm` — is what poses it before `tool.set` "
             ~ "returns. T-X7 below is the row that pins "
             ~ "that half, and it fails on its own terms.", piv[0], piv[1], piv[2]));
}

// ---------------------------------------------------------------------------
// T-X7 — THE TOOL IS POSED BY THE TIME `tool.set` RETURNS.
//
// The two channels onto one quantity must agree in the instant right after
// arming: the tool's own resident pivot (`/api/tool/state`, answered straight
// off the HTTP thread from `moveSub.handler.center`) and the pipe's action
// centre (`/api/toolpipe/eval`, evaluated on the main thread from the stage).
//
// WHAT THIS CATCHES, and why the suite had no cell for it. `activate()` poses
// nothing, and the pose's only writer used to be the top of `update()`/
// `draw()` — so between the command bridge draining `tool.set` at the top of
// the frame and that same frame reaching `activeTool.update(vts)`, the tool
// held its constructor's `Vec3(0,0,0)` and the route reported it. The window
// is sub-millisecond on hardware GL: it opened ONCE in 689 tests on the
// nightly runner under software GL and never once in 70 deliberate attempts
// here. Repetition cannot test it. What CAN is this comparison, because it
// asserts the invariant the fix establishes — the two channels agree at the
// instant of arming — rather than waiting for the race to show itself.
//
// SO IT IS READ ONCE, IN THIS ORDER, AND ON PURPOSE. The tool-state read is
// the EARLY channel (HTTP thread, no main-loop pass needed) and goes first;
// the eval read is marshalled onto the main thread and can only be later. No
// settle: `toolPivot`'s bounded poll exists for the other rows, and using it
// here would poll away exactly the state this row is about.
//
// THE DEGENERACY GUARD IS NOT DECORATION. "Two channels agree" is satisfied by
// both reading (0,0,0), which is precisely the shape of the defect, so a
// fixture whose action centre sat at the origin would pass this row on the
// broken product. `planeFixture` puts it at (4.25, 1.5, -2) and the guard
// asserts that it did — the comparison is only evidence while the agreed
// value is one the un-ticked tool could not have produced.
//
// `subject` is the second, independent witness of the same tick. It is
// `cachedSubjType_`, refreshed from the same packet the pose is derived from,
// and a pre-tick read answers "component" — the constructor's `SelType.Vertex`
// — while the document is in Item selection. One snapshot, two fields, one
// cause; if only one of them is wrong the fix has come apart in a way worth
// knowing about separately.
// ---------------------------------------------------------------------------
unittest {
    planeFixture();
    cmd("tool.set move on");
    scope (exit) cmd("tool.set move off");

    auto st   = toolState();          // early channel, one read, no settle
    auto piv  = pivotOf(st);
    auto acen = actionCentre();       // late channel, main-thread marshalled

    assert(!(approx(acen[0], 0.0) && approx(acen[1], 0.0) && approx(acen[2], 0.0)),
        format("T-X7 degeneracy guard: the fixture's action centre must NOT "
             ~ "be the origin, or 'the two channels agree' is satisfied by the "
             ~ "very failure this row exists to catch. got (%.4f, %.4f, %.4f) "
             ~ "— check planeFixture still poses the plane away from it",
               acen[0], acen[1], acen[2]));

    assert(approx(piv[0], acen[0]) && approx(piv[1], acen[1])
        && approx(piv[2], acen[2]),
        format("T-X7: the instant `tool.set` returns, the tool's own pivot and "
             ~ "the pipe's action centre must be the SAME point. tool "
             ~ "(%.4f, %.4f, %.4f) vs pipe (%.4f, %.4f, %.4f).\n"
             ~ "  A tool pivot of (0,0,0) against a non-zero pipe centre is "
             ~ "the signature: the tool was read before it was ever ticked. "
             ~ "`tool.set` builds a FRESH tool, `activate()` poses nothing, "
             ~ "and the prepared arm's initial-pose door — "
             ~ "`PreparedToolPoseDoorClient.prepareDoorInitialPose`, fed the "
             ~ "tool-vts packet inside `prepareArm` — is what closes that. "
             ~ "If that door is gone, unwired, or moved after the pose is "
             ~ "read, this is what "
             ~ "you get. Reproduce it deterministically: set "
             ~ "VIBE3D_STALL_PRE_TOOL_TICK_MS=250 (source/frame_stall.d) and "
             ~ "the window this row aims at is wide open.",
               piv[0], piv[1], piv[2], acen[0], acen[1], acen[2]));

    assert(st["subject"].str == "item",
        "T-X7: …and the same tick must have refreshed the cached subject "
        ~ "type. \"component\" here is the freshly built tool's constructor "
        ~ "default (SelType.Vertex) on a document that is in ITEM selection — "
        ~ "the same un-ticked tool the pivot assertion above describes, seen "
        ~ "through a second field of the same snapshot. got " ~ st.toString);
}

// ---------------------------------------------------------------------------
// T-X2 — the moving set: the plane moves, the mesh does not; ctrl-add the
// mesh and both move. Plus the derived `transformTarget` field in both states.
//
// Wrong implementation: the ungated moving set (option A, "leave it"). The
// mesh's `xform` text changes in the first half — a character silently
// carrying a non-identity item transform into every export.
// ---------------------------------------------------------------------------
unittest {
    planeFixture();

    // --- the plane selected: only the plane is a transform target ---------
    assert(isXTarget(1), "T-X2: the focused plane is in the moving set");
    assert(!isXTarget(0),
        "T-X2: the forced mesh is NOT — and `selected` alone can no longer "
        ~ "answer 'will the gizmo move this', which is why the field exists");
    assert(layerAt(0)["selected"].boolean,
        "T-X2: …while the mesh stays SELECTED. The narrowing is of the "
        ~ "moving set, never of the selection — collapsing the two would make "
        ~ "the Layers panel and the gizmo disagree about what the user picked");

    string meshBefore = xformText(0);
    double planeBefore = posX(1);
    moveX(2.5);

    assert(approx(posX(1), planeBefore + 2.5, 1e-3),
        format("T-X2: the plane must move by exactly the applied TX — "
             ~ "expected %.4f, got %.4f", planeBefore + 2.5, posX(1)));
    assert(xformText(0) == meshBefore,
        "T-X2: the mesh's item transform must be BYTE-IDENTICAL after a "
        ~ "gesture aimed at the plane. An ungated moving set writes pos.x "
        ~ "here — before: " ~ meshBefore ~ " after: " ~ xformText(0));

    // --- ctrl-add the mesh: both are targets again, and both move ---------
    cmd("layer.select index:0 mode:add");
    assert(isXTarget(0) && isXTarget(1),
        "T-X2: ctrl-adding the mesh re-homes the focus onto it, so the "
        ~ "narrowing lifts and BOTH layers are targets again");

    string meshBefore2  = xformText(0);
    double meshPosX2    = posX(0);
    double planeBefore2 = posX(1);
    moveX(1.25);

    assert(approx(posX(0), meshPosX2 + 1.25, 1e-3),
        format("T-X2: with both selected the MESH moves too — expected %.4f, "
             ~ "got %.4f", meshPosX2 + 1.25, posX(0)));
    assert(approx(posX(1), planeBefore2 + 1.25, 1e-3),
        format("T-X2: …and so does the plane — expected %.4f, got %.4f",
               planeBefore2 + 1.25, posX(1)));
    assert(xformText(0) != meshBefore2,
        "T-X2 self-check: the byte-identical probe used in the first half "
        ~ "must be capable of reporting a CHANGE, or that assertion proved "
        ~ "nothing about the gesture and everything about the probe");
}

// ---------------------------------------------------------------------------
// T-X3 — one gesture is one undo entry, and one undo restores every target.
//
// Wrong implementation: per-target undo entries (one per moved item). With
// two items in the set that reads 2, and undoing the plane's move would take
// two Ctrl+Z. The TWO-item fixture is what makes this able to fail — a
// one-item set cannot tell "one entry per gesture" from "one entry per
// target", which is the shape a reviewer counting green lines would miss.
//
// THIS ROW USES A REAL GIZMO DRAG, and the reason is a finding, not a
// preference. `tool.doApply` records `ToolDoApplyCommand`, whose `revert()`
// restores a `MeshSnapshot` (`commands/tool/do_apply.d`) — mesh vertices and
// marks. In Item mode the tool writes `Layer.xform`, which that snapshot does
// not cover, so the headless path records an entry that reverts NOTHING. It
// reproduces on a one-mesh document with no plane in it, i.e. on the
// pre-Stage-8 code path, so it is pre-existing (task 0614's headless
// one-shot) and out of this stage's scope — this stage must not change undo
// granularity. Logged rather than fixed. The interactive path, which is what
// a user actually drives, records through `commitItemEdit` and is correct.
//
// The mesh is added LAST so the focus lands on it: the gizmo then sits at the
// cube's origin pivot, where the default camera already looks, and the drag
// helper needs no camera move. Both layers are still in the set.
// ---------------------------------------------------------------------------
unittest {
    planeFixture();
    cmd("layer.select index:0 mode:add");     // TWO targets in the set
    assert(isXTarget(0) && isXTarget(1), "fixture: two targets, not one");

    double meshBefore  = posX(0);
    double planeBefore = posX(1);
    long   undoBefore  = history()["undo"].array.length;

    post(BASE ~ "/api/script", "tool.set move");
    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    int gx, gy; double ux, uy;
    axisGrabPx(Vec3(0, 0, 0), vp, gx, gy, ux, uy);   // the focused mesh's pivot
    playAndWait(buildDragLog(vp.x, vp.y, vp.width, vp.height,
                             gx, gy,
                             gx + cast(int)(60.0 * ux),
                             gy + cast(int)(60.0 * uy)));
    post(BASE ~ "/api/script", "tool.set move off");  // tool drop = run boundary

    assert(!approx(posX(0), meshBefore) && !approx(posX(1), planeBefore),
        format("T-X3 sanity: the drag must have moved BOTH targets — mesh "
             ~ "%.6f (was %.6f), plane %.6f (was %.6f)",
               posX(0), meshBefore, posX(1), planeBefore));

    long undoAfter = history()["undo"].array.length;
    assert(undoAfter == undoBefore + 2,
        format("T-X3: one arm plus one gesture over TWO targets is TWO surfaced rows — "
             ~ "before=%d after=%d", undoBefore, undoAfter));

    doUndo();
    assert(approx(posX(1), planeBefore, 1e-6) && approx(posX(0), meshBefore, 1e-6),
        format("T-X3: a single undo restores BOTH targets exactly — "
             ~ "plane %.6f (want %.6f), mesh %.6f (want %.6f)",
               posX(1), planeBefore, posX(0), meshBefore));
}

// ---------------------------------------------------------------------------
// T-X5 — select the plane, then Ctrl+Z: the gizmo still moves something.
//
// This is the test that killed the WITHDRAWN option C (a stored "the primary
// was force-re-added" bool on `Document`). The three selection `revert`s
// restore `l.selected` with raw writes that bypass every mutator, so C's bit
// would survive the undo with nothing selected to justify it and the moving
// set would come back EMPTY — a gizmo that drags nothing, silently. D has no
// state to go stale: `LayerSelect.revert` calls `setPrimary`, which homes the
// focus onto the primary, and the narrowing lifts by derivation.
// ---------------------------------------------------------------------------
// MEASURED HERE, and it is why this row is not written the way the plan
// specifies it: `/api/undo` (and the Ctrl+Z it stands in for) takes ONE
// MODEL step and carries the UI-class entries stacked on top of it along for
// the ride. Probed on this build: a stack of
// [Add Image Plane, Select Layer, Select Layer] is emptied by a SINGLE undo,
// and the plane is gone. So "select the plane, then Ctrl+Z, and the selection
// undo alone is reverted" is not a state this app can reach — the plan's
// wording assumed a per-selection undo step. What the row is FOR survives
// intact and is what is asserted: after the undo the moving set must not be
// EMPTY, and whatever it does contain must be what moves.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmd(`{"id":"imagePlane.add","params":{"name":"Ref","projection":"front"}}`);
    cmd("layer.select index:0 mode:set");      // the mesh
    cmd("layer.select index:1 mode:set");      // …then the plane
    assert(!isXTarget(0) && isXTarget(1),
        "fixture: the narrowing is actually in effect before the undo — "
        ~ "without this the post-undo state could be the pre-undo one");

    doUndo();

    // Whatever the undo landed on, the moving set must be derivable from it.
    size_t targets = 0;
    foreach (l; layers().array) if (l["transformTarget"].boolean) ++targets;
    assert(targets > 0,
        "T-X5: after an undo the moving set must not be EMPTY. This is the "
        ~ "assertion that killed the withdrawn option C (a stored 'the "
        ~ "primary was force-re-added' bool): the three selection reverts "
        ~ "write `l.selected` RAW, bypassing every mutator, so C's bit would "
        ~ "survive with nothing to justify it and the gizmo would drag "
        ~ "nothing, silently. D stores nothing and cannot go stale.");

    // …and it must be the layers the set NAMES that move, not some other set.
    bool[] wasTarget;
    double[] before;
    foreach (l; layers().array) {
        wasTarget ~= l["transformTarget"].boolean;
        before    ~= l["xform"]["pos"].array[0].floating;
    }
    moveX(2.0);
    foreach (i, t; wasTarget) {
        immutable got = posX(i);
        if (t)
            assert(approx(got, before[i] + 2.0, 1e-3),
                format("T-X5: layer %d was reported as a transform target and "
                     ~ "must have moved — expected %.4f, got %.4f",
                       i, before[i] + 2.0, got));
        else
            assert(approx(got, before[i], 1e-6),
                format("T-X5: layer %d was NOT a transform target and must "
                     ~ "not have moved — was %.6f, got %.6f",
                       i, before[i], got));
    }
}

// ---------------------------------------------------------------------------
// T-X6 — THE DECLARED DIVERGENCE. Asserted, not merely documented.
//
// Select the mesh, THEN ctrl-add the plane: under the measured reference both
// move; under vibe3d's approximation only the plane does. This assertion is
// the acceptance test the follow-up task ("unlatch the geometry edit target
// from selection membership", model M) inherits — when the real separation
// lands it must start asserting the OPPOSITE, deliberately, rather than
// discovering the change as a regression.
//
// Note the ORDER is what makes this row different from T-X2's second half.
// There the mesh was added LAST, so the focus landed on it (a mesh can be
// primary) and nothing was narrowed. Here the PLANE is added last, so the
// focus lands on the plane while `primary` stays the mesh — and D subtracts
// the primary. Same two layers, same two commands, opposite outcome; that
// asymmetry IS the divergence, and it is why both halves are in this file.
// ---------------------------------------------------------------------------
unittest {
    planeFixture();
    cmd("layer.select index:0 mode:set");     // mesh alone
    assert(isXTarget(0) && !layerAt(1)["selected"].boolean,
        "fixture: start from the mesh selected ALONE");

    cmd("layer.select index:1 mode:add");     // ctrl-ADD the plane
    assert(layerAt(0)["selected"].boolean && layerAt(1)["selected"].boolean,
        "fixture: both are selected — the divergence is about the moving "
        ~ "set, and if the ADD had not selected both there would be no "
        ~ "divergence to observe");
    assert(layerAt(1)["focused"].boolean,
        "fixture: adding the plane last moves the FOCUS onto it, which is "
        ~ "the state that triggers the narrowing");

    string meshBefore  = xformText(0);
    double planeBefore = posX(1);
    moveX(2.0);

    assert(approx(posX(1), planeBefore + 2.0, 1e-3),
        "T-X6 control: the plane DOES move — without this the assertion "
        ~ "below would also pass on a gesture that did nothing at all");
    assert(xformText(0) == meshBefore,
        "T-X6 — DECLARED DIVERGENCE (vibe3d-divergence, task 0612 §7.2). "
        ~ "The reference moves BOTH here; vibe3d moves only the focused "
        ~ "item. This is our deliberate approximation of a latched edit "
        ~ "target that is not a selection member, and it UNDER-moves: one "
        ~ "ctrl-click on the mesh recovers it, whereas the alternative "
        ~ "available without the document-model change OVER-moves on the "
        ~ "common path. If you are reading this failure while implementing "
        ~ "model M, this is the assertion you are meant to flip. "
        ~ "before: " ~ meshBefore ~ " after: " ~ xformText(0));
}

// ---------------------------------------------------------------------------
// T-X4 — the CONTROL, and the whole neutrality argument for this stage.
//
// An all-mesh document must be bit-for-bit unaffected: every mesh-kind
// selection route leaves focus and primary equal, so the narrowing term can
// never fire. The sixteen `tests/*item*` files passing UNEDITED are the broad
// form of this proof; this is the narrow, local one — a two-mesh document
// where a "drop the primary whenever anything else is selected" reading of D
// would move only one of them.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("layer.add");                          // a second MESH
    assert(layers().array.length == 2 && layerAt(1)["type"].str == "mesh",
        "fixture: two MESH layers, so focus and primary can never diverge");
    cmd("layer.select index:0 mode:set");
    cmd("layer.select index:1 mode:add");
    assert(isXTarget(0) && isXTarget(1),
        "T-X4: on an all-mesh document every selected layer is a transform "
        ~ "target — the narrowing term is unreachable here");

    double a = posX(0), b = posX(1);
    moveX(1.5);
    assert(approx(posX(0), a + 1.5, 1e-3) && approx(posX(1), b + 1.5, 1e-3),
        format("T-X4: a multi-MESH drag moves every member, exactly as "
             ~ "before this stage — got %.4f (want %.4f) and %.4f (want %.4f)",
               posX(0), a + 1.5, posX(1), b + 1.5));
}
