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

import std.net.curl;
import std.json;
import std.math   : fabs;
import std.conv   : to;
import std.format : format;

import drag_helpers;

void main() {}

immutable BASE = "http://localhost:8080";

JSONValue getJson(string path) { return parseJSON(cast(string) get(BASE ~ path)); }

JSONValue cmd(string argstring) {
    auto j = parseJSON(cast(string) post(BASE ~ "/api/command", argstring));
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
    return j;
}

void resetCube() {
    auto j = parseJSON(cast(string) post(BASE ~ "/api/reset", ""));
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

JSONValue doUndo() { return parseJSON(cast(string) post(BASE ~ "/api/undo", "")); }

/// The shared gizmo centre the tool publishes — `ActionCenterStage`'s answer,
/// read through the tool rather than inferred from a drag.
double[3] toolPivot() {
    auto st = getJson("/api/tool/state");
    assert("pivot" in st,
        "the active tool must publish a pivot — got " ~ st.toString);
    auto p = st["pivot"].array;
    return [p[0].floating, p[1].floating, p[2].floating];
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
/// cube's. `imagePlane.add` folds the selection in, so on return the plane is
/// the focus and the mesh is still the (forced) primary.
void planeFixture() {
    resetCube();
    cmd(`{"id":"imagePlane.add","params":{"name":"Ref","projection":"front"}}`);
    assert(layers().array.length == 2, "fixture: cube + plane");
    assert(layerAt(1)["type"].str == "imagePlane", "fixture: layer 1 is the plane");
    cmd("layer.attr 1 pos.x 4.0");
    cmd("layer.attr 1 pos.y 1.5");
    cmd("layer.attr 1 pos.z -2.0");
    cmd("layer.attr 1 pivot.x 0.25");
    cmd("layer.select index:1 mode:set");
    // Vacuity guards. Without these, every assertion below could be passing
    // on a document that simply does not hold the state it claims to.
    assert(layerAt(0)["primary"].boolean,
        "vacuity: the MESH is still the mesh edit target — a plane can never "
        ~ "be one, and if it could there would be nothing to narrow");
    assert(layerAt(0)["selected"].boolean,
        "vacuity: the document invariant FORCES the mesh to stay selected "
        ~ "alongside the plane. If this ever reads false the approximation "
        ~ "this file tests has become unnecessary — see model M");
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
// ---------------------------------------------------------------------------
unittest {
    planeFixture();
    cmd("tool.set move on");
    scope (exit) cmd("tool.set move off");

    auto piv = toolPivot();
    assert(approx(piv[0], 4.25) && approx(piv[1], 1.5) && approx(piv[2], -2.0),
        format("T-X1: the gizmo centre must be the FOCUSED item's world pivot "
             ~ "(pos + pivot = 4.25, 1.5, -2). A binding still reading "
             ~ "document.primary reports the cube's (0,0,0) — the gizmo "
             ~ "sitting on the character while the panel shows the plane. "
             ~ "got (%.4f, %.4f, %.4f)", piv[0], piv[1], piv[2]));
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
    assert(undoAfter == undoBefore + 1,
        format("T-X3: one gesture over TWO targets is ONE undo entry — "
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
