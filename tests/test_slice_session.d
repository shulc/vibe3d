// Slice tool (mesh.sliceTool) INTERACTIVE SESSION lifecycle (task 0278).
//
// Proves the two invariants the owner bug report demanded:
//   1. TWO successive endpoint/line drags in ONE tool session produce exactly
//      ONE slice (12v/10f cube cut), not two — dragging refines the SAME cut
//      non-cumulatively from the ACTIVATION baseline. The pre-0278 code
//      committed on every mouse-up, so the second drag cut the already-cut
//      mesh and stacked a second slice (~16v); this test would show >12 verts
//      under that bug.
//   2. The cut is baked into EXACTLY ONE undo entry, and only at tool-drop
//      (deactivate) — NOT on mouse-up. The undo count is unchanged after each
//      drag's release and grows by exactly 1 when the tool is switched off.
//
// Camera-agnostic: the test reconstructs the same viewport vibe3d uses, picks
// the same most-facing construction plane the tool's workplaneHit will pick,
// and lays the slice line on that plane so the cut always crosses the cube in
// a clean 4-edge belt (12v/10f) regardless of the default orbit orientation.
//
// Drives real SDL mouse-down/motion/up sequences through /api/play-events (the
// interactive path — NOT the headless tool.doApply path the topology-diff
// fixtures use), so it exercises the actual onMouseButtonDown/Motion/Up +
// deactivate lifecycle.

import std.net.curl;
import std.json;
import std.math  : abs, fabs;
import std.format : format;
import core.thread : Thread;
import core.time   : dur;

import drag_helpers;   // Vec3, Viewport, fetchCamera, viewportFromCamera, projectToWindow, buildDragLog, playAndWait

void main() {}

enum string BASE = "http://localhost:8080";

void cmd(string s) {
    auto resp = cast(string) post(BASE ~ "/api/command", s);
    assert(parseJSON(resp)["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ resp);
}

void resetCube() {
    auto resp = cast(string) post(BASE ~ "/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset failed: " ~ resp);
}

JSONValue getModel()     { return parseJSON(cast(string) get(BASE ~ "/api/model")); }
JSONValue getToolState() { return parseJSON(cast(string) get(BASE ~ "/api/tool/state")); }
long undoCount()         { return parseJSON(cast(string) get(BASE ~ "/api/history"))["undo"].array.length; }

size_t vertCount() { return getModel()["vertices"].array.length; }
size_t faceCount() { return getModel()["faces"].array.length; }

JSONValue getSelection() { return parseJSON(cast(string) get(BASE ~ "/api/selection")); }
// Number of currently-selected elements of the given kind
// ("selectedVertices" / "selectedEdges" / "selectedFaces").
size_t selCount(string key) { return getSelection()[key].array.length; }

void settle() { Thread.sleep(dur!"msecs"(180)); }   // post-playback drain guard

// Screen pixel for a world point on the active viewport.
void scr(Vec3 w, const ref Viewport vp, out int px, out int py) {
    float fx, fy;
    bool ok = projectToWindow(w, vp, fx, fy);
    assert(ok, "world point projected off-screen — camera assumptions broke");
    px = cast(int) (fx + 0.5f);
    py = cast(int) (fy + 0.5f);
}

unittest {
    resetCube();
    assert(vertCount() == 8 && faceCount() == 6, "fresh cube must be 8v/6f");
    immutable long baseUndo = undoCount();

    // Activate the interactive Slice tool (captures the SESSION baseline now).
    cmd("tool.set mesh.sliceTool on");
    settle();

    auto cam = fetchCamera(BASE);
    auto vp  = viewportFromCamera(cam);

    // Replicate the tool's auto construction plane (pickMostFacingPlane): the
    // world axis whose |dot(camBack)| is largest is the plane normal; the other
    // two world axes span it. Tie-break X>Y>Z, matching mostFacingAxis.
    Vec3 camBack = Vec3(vp.view[2], vp.view[6], vp.view[10]);
    float ax = fabs(camBack.x), ay = fabs(camBack.y), az = fabs(camBack.z);
    Vec3 ax1, ax2;   // in-plane spanning axes (axis1, axis2 as pickMostFacingPlane orders them)
    if (ax >= ay && ax >= az)       { ax1 = Vec3(0,1,0); ax2 = Vec3(0,0,1); }
    else if (ay >= ax && ay >= az)  { ax1 = Vec3(1,0,0); ax2 = Vec3(0,0,1); }
    else                            { ax1 = Vec3(1,0,0); ax2 = Vec3(0,1,0); }

    // Line ALONG ax2 (never collinear with the idle default ±X line, so drag 1
    // draws a fresh line rather than grabbing the default), SHIFT along ax1.
    Vec3 U = ax2, V = ax1;

    // ---- Drag 1: draw a fresh mid-plane line through the origin ------------
    // (else-branch: click away from any existing handle/line, drag the End).
    Vec3 A1 = U * (-0.6f), B1 = U * (0.6f);
    int a1x, a1y, b1x, b1y;
    scr(A1, vp, a1x, a1y);
    scr(B1, vp, b1x, b1y);
    playAndWait(buildDragLog(vp.x, vp.y, vp.width, vp.height, a1x, a1y, b1x, b1y, 20, 0), BASE);
    settle();

    // ONE slice is live, and NOTHING committed yet (deferred to tool-drop).
    assert(vertCount() == 12 && faceCount() == 10,
           format("drag 1 must show one mid-plane cut (12v/10f), got %dv/%df",
                  vertCount(), faceCount()));
    assert(undoCount() == baseUndo,
           "mouse-up must NOT commit — undo count changed after drag 1");

    // ---- Drag 2: grab the LINE BODY and translate it (a second gesture) ----
    // The midpoint (origin) projects clear of the endpoints (0.6 world units
    // away), so pickHandle misses and pickLineBody grabs the whole line.
    Vec3 mid0  = Vec3(0, 0, 0);
    Vec3 mid1  = V * 0.3f;               // shift the line 0.3 along the in-plane axis
    int m0x, m0y, m1x, m1y;
    scr(mid0, vp, m0x, m0y);
    scr(mid1, vp, m1x, m1y);
    playAndWait(buildDragLog(vp.x, vp.y, vp.width, vp.height, m0x, m0y, m1x, m1y, 20, 0), BASE);
    settle();

    // STILL exactly one slice — the second drag refined the SAME cut, it did
    // NOT stack a second (the pre-0278 per-mouse-up commit would show ~16v).
    assert(vertCount() == 12 && faceCount() == 10,
           format("two drags must refine ONE slice, not stack — got %dv/%df",
                  vertCount(), faceCount()));
    assert(undoCount() == baseUndo,
           "mouse-up must NOT commit — undo count changed after drag 2");

    // Self-diagnostic: the line-body drag actually translated the WHOLE line
    // (both endpoints moved ~0.3 along V, so the midpoint sits at ~0.3·V). This
    // guards that drag 2 was a line-translate, not a stray endpoint grab.
    auto st = getToolState();
    Vec3 s2 = Vec3(cast(float)st["startX"].floating, cast(float)st["startY"].floating,
                   cast(float)st["startZ"].floating);
    Vec3 e2 = Vec3(cast(float)st["endX"].floating, cast(float)st["endY"].floating,
                   cast(float)st["endZ"].floating);
    Vec3 mid = (s2 + e2) * 0.5f;
    float midAlongV = mid.x*V.x + mid.y*V.y + mid.z*V.z;
    assert(fabs(midAlongV - 0.3f) < 0.15f,
           format("line-body drag should shift the line ~0.3 along V, got %.3f", midAlongV));

    // ---- Bake on deactivate: exactly ONE undo entry per session -----------
    cmd("tool.set mesh.sliceTool off");
    settle();
    assert(undoCount() == baseUndo + 1,
           format("tool-drop must bake exactly ONE undo entry, got delta %d",
                  undoCount() - baseUndo));
    assert(vertCount() == 12 && faceCount() == 10,
           "the committed slice must remain after tool-drop");

    // The single entry restores the pristine cube on undo.
    auto ur = cast(string) post(BASE ~ "/api/undo", "");
    assert(parseJSON(ur)["status"].str == "ok", "/api/undo failed: " ~ ur);
    settle();
    assert(vertCount() == 8 && faceCount() == 6,
           "one undo must restore the pristine 8v/6f cube");
    assert(undoCount() == baseUndo, "undo must return to the pre-session count");
}

// ---------------------------------------------------------------------------
// Activate Slice, draw ONE clean mid-plane cut through the origin, and drop the
// tool (bakes the single undo entry). Camera-agnostic — reconstructs the same
// most-facing construction plane the tool picks and lays the line on it, so the
// cut always crosses the cube in a 4-edge belt (8v/6f → 12v/10f). Mirrors
// "drag 1" of the session test above; used by the post-tool-selection tests.
void sliceOnceMidPlane() {
    cmd("tool.set mesh.sliceTool on");
    settle();

    auto cam = fetchCamera(BASE);
    auto vp  = viewportFromCamera(cam);

    Vec3 camBack = Vec3(vp.view[2], vp.view[6], vp.view[10]);
    float ax = fabs(camBack.x), ay = fabs(camBack.y), az = fabs(camBack.z);
    Vec3 ax2;   // in-plane axis to lay the line along
    if (ax >= ay && ax >= az)       ax2 = Vec3(0,0,1);
    else if (ay >= ax && ay >= az)  ax2 = Vec3(0,0,1);
    else                            ax2 = Vec3(0,1,0);

    Vec3 A1 = ax2 * (-0.6f), B1 = ax2 * (0.6f);
    int a1x, a1y, b1x, b1y;
    scr(A1, vp, a1x, a1y);
    scr(B1, vp, b1x, b1y);
    playAndWait(buildDragLog(vp.x, vp.y, vp.width, vp.height, a1x, a1y, b1x, b1y, 20, 0), BASE);
    settle();

    cmd("tool.set mesh.sliceTool off");
    settle();
}

// ---------------------------------------------------------------------------
// S2 — post-tool selection: Slice does NOT auto-select the new geometry (unlike
// Loop Slice's `selectNew`). With NOTHING pre-selected, the committed cut leaves
// the selection EMPTY — the incoming (empty) selection is preserved verbatim.
// The cut kernel (Mesh.cutByPlane → rebuildFacesWithChordSplits) clears face /
// edge selection and adds the new crossing verts UNSELECTED; nothing in the
// slice path or the baked MeshBevelEdit re-selects. Reference capture: "with
// nothing pre-selected, 0 polygons selected after the cut".
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    assert(vertCount() == 8 && faceCount() == 6, "fresh cube must be 8v/6f");
    // A fresh cube starts with an EMPTY selection — the precondition for the
    // nothing-in ⇒ nothing-out invariant.
    assert(selCount("selectedVertices") == 0 &&
           selCount("selectedEdges")    == 0 &&
           selCount("selectedFaces")    == 0,
           "fresh cube must have an empty selection before the slice");
    immutable long baseUndo = undoCount();

    sliceOnceMidPlane();

    // The cut actually happened (one baked undo entry, 12v/10f) — so the
    // selection assertions below are meaningful, not a no-op.
    assert(vertCount() == 12 && faceCount() == 10,
           format("slice must have cut the cube (12v/10f), got %dv/%df",
                  vertCount(), faceCount()));
    assert(undoCount() == baseUndo + 1,
           "tool-drop must bake exactly one undo entry for the cut");

    // The hard S2 requirement: NOTHING is auto-selected. Slice preserves the
    // (empty) incoming selection — no new polygon / edge / vertex is selected.
    assert(selCount("selectedVertices") == 0, "Slice must not auto-select vertices");
    assert(selCount("selectedEdges")    == 0, "Slice must not auto-select edges");
    assert(selCount("selectedFaces")    == 0, "Slice must not auto-select polygons");
}

// ---------------------------------------------------------------------------
// S2 (soft) — a pre-existing VERTEX selection survives the slice unchanged. The
// original cube verts keep their indices (crossing verts are only APPENDED), so
// the incoming selection {0,1} is still exactly {0,1} after the committed cut —
// no new (cut) vertex is auto-added. This confirms "leaves the incoming
// selection unchanged" in the non-empty case too, for the selection kind the
// cut does not clear.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    // Pre-select two original cube vertices BEFORE activating the tool, so the
    // session baseline is captured WITH this selection.
    cmd("select.element vertex set 0 1");
    settle();
    assert(selCount("selectedVertices") == 2, "pre-selection of 2 verts must take");

    sliceOnceMidPlane();

    assert(vertCount() == 12 && faceCount() == 10,
           format("slice must have cut the cube (12v/10f), got %dv/%df",
                  vertCount(), faceCount()));

    // The incoming vertex selection is preserved verbatim: verts 0 & 1 stay
    // selected and no cut vertex is auto-selected (count stays 2).
    auto sv = getSelection()["selectedVertices"].array;
    assert(sv.length == 2,
           format("incoming 2-vertex selection must survive the cut, got %d", sv.length));
    bool has0 = false, has1 = false;
    foreach (j; sv) {
        if (j.integer == 0) has0 = true;
        if (j.integer == 1) has1 = true;
    }
    assert(has0 && has1, "verts 0 and 1 must remain selected after the cut");
}
