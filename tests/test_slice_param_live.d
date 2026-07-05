// Slice tool (mesh.sliceTool) — LIVE panel-edit re-preview (task 0283).
//
// Owner bug: editing a Tool Properties parameter (split/caps/gap/gapSide/axis/
// vector/infinite/snap/snapAngle, or the start/end coords) only took effect on
// the NEXT slice — it did NOT re-apply to the CURRENT live slice. The fix wires
// SliceTool.onParamChanged so a cut-affecting param edit re-previews the current
// slice from the activation baseline immediately.
//
// This test:
//   1. Activates the interactive Slice tool and draws ONE clean mid-plane cut
//      via a real SDL drag (leaving the tool ACTIVE — no drop).
//   2. Changes a param via /api/command tool.attr and asserts the CURRENT mesh
//      geometry changed IMMEDIATELY — before any new drag / new slice.
//        - `split 1`   → the connected cut splits into two disconnected shells
//          (vertex count grows: the cut loop is duplicated).
//        - `gap 0.2` (with split on) → shells separate, verts move apart.
//        - editing `startX` (a line endpoint) → the cut moves.
//   3. Confirms `fast` gating does NOT block a panel edit (re-preview regardless).
//
// Camera-agnostic: reconstructs the same most-facing construction plane the tool
// picks and lays the slice line on it (mirrors test_slice_session.d).

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

size_t vertCount() { return getModel()["vertices"].array.length; }
size_t faceCount() { return getModel()["faces"].array.length; }

// Sum of absolute vertex coordinates over all axes. Camera-agnostic geometry
// fingerprint: a gap pushes the split cut-loop verts OFF the plane (from 0 to
// ±gap/2 along the cut-plane normal, whatever world axis that is), so this sum
// grows measurably even though those verts stay inside the cube's ±0.5 bounds.
double sumAbsCoord() {
    auto vs = getModel()["vertices"].array;
    double s = 0;
    foreach (v; vs)
        foreach (c; v.array)
            s += fabs(c.floating);
    return s;
}

void settle() { Thread.sleep(dur!"msecs"(180)); }   // post-playback drain guard

void scr(Vec3 w, const ref Viewport vp, out int px, out int py) {
    float fx, fy;
    bool ok = projectToWindow(w, vp, fx, fy);
    assert(ok, "world point projected off-screen — camera assumptions broke");
    px = cast(int) (fx + 0.5f);
    py = cast(int) (fy + 0.5f);
}

// Activate Slice and draw ONE mid-plane cut through the origin, LEAVING the tool
// active. Returns the in-plane axis the line was laid along and the viewport, so
// the caller can drive further param edits / endpoint math. Mirrors "drag 1" of
// test_slice_session.d.
Viewport sliceOnceLeaveActive(out Vec3 lineAxis) {
    cmd("tool.set mesh.sliceTool on");
    settle();

    auto cam = fetchCamera(BASE);
    auto vp  = viewportFromCamera(cam);

    Vec3 camBack = Vec3(vp.view[2], vp.view[6], vp.view[10]);
    float ax = fabs(camBack.x), ay = fabs(camBack.y), az = fabs(camBack.z);
    Vec3 ax2;
    if (ax >= ay && ax >= az)       ax2 = Vec3(0,0,1);
    else if (ay >= ax && ay >= az)  ax2 = Vec3(0,0,1);
    else                            ax2 = Vec3(0,1,0);
    lineAxis = ax2;

    Vec3 A1 = ax2 * (-0.6f), B1 = ax2 * (0.6f);
    int a1x, a1y, b1x, b1y;
    scr(A1, vp, a1x, a1y);
    scr(B1, vp, b1x, b1y);
    playAndWait(buildDragLog(vp.x, vp.y, vp.width, vp.height, a1x, a1y, b1x, b1y, 20, 0), BASE);
    settle();
    return vp;
}

// ---------------------------------------------------------------------------
// LIVE panel-edit re-preview: split / gap change the CURRENT slice immediately.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    assert(vertCount() == 8 && faceCount() == 6, "fresh cube must be 8v/6f");

    Vec3 lineAxis;
    sliceOnceLeaveActive(lineAxis);

    // The live (connected) mid-plane cut: 12v/10f. Tool is STILL ACTIVE.
    assert(vertCount() == 12 && faceCount() == 10,
           format("mid-plane slice must be live (12v/10f), got %dv/%df",
                  vertCount(), faceCount()));

    // ---- Edit `split` via panel → the current cut re-previews IMMEDIATELY ----
    // Split duplicates the cut loop into two coincident boundary loops, so the
    // vertex count grows (the connected 12v cut becomes a split shell pair). No
    // new drag, no tool drop — the geometry must change on the attr write alone.
    cmd("tool.attr mesh.sliceTool split 1");
    settle();
    size_t vSplit = vertCount();
    assert(vSplit > 12,
           format("panel `split 1` must re-cut the CURRENT slice immediately " ~
                  "(more verts than the 12v connected cut), got %dv", vSplit));
    // tool/state must echo the new value too.
    assert(getToolState()["split"].boolean == true, "split attr must be set");

    // ---- Edit `gap` via panel → shells separate, geometry moves ----
    // gap=0.3 pushes the 8 duplicated cut-loop verts off the plane by ±0.15
    // along the cut-plane normal, so the sum of |coords| grows immediately.
    double sumBefore = sumAbsCoord();
    cmd("tool.attr mesh.sliceTool gap 0.3");
    settle();
    double sumAfter = sumAbsCoord();
    assert(sumAfter - sumBefore > 1e-3,
           format("panel `gap 0.3` must move the split shells immediately " ~
                  "(sumAbsCoord %.4f -> %.4f)", sumBefore, sumAfter));

    // ---- Turn split back OFF via panel → back to the connected cut ----
    cmd("tool.attr mesh.sliceTool split 0");
    settle();
    assert(vertCount() == 12 && faceCount() == 10,
           format("panel `split 0` must restore the connected 12v/10f cut, got %dv/%df",
                  vertCount(), faceCount()));

    cmd("tool.set mesh.sliceTool off");
    settle();
}

// ---------------------------------------------------------------------------
// LIVE panel-edit re-preview: editing an ENDPOINT coord moves the cut.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    assert(vertCount() == 8 && faceCount() == 6, "fresh cube must be 8v/6f");

    Vec3 lineAxis;
    sliceOnceLeaveActive(lineAxis);
    assert(vertCount() == 12 && faceCount() == 10, "mid-plane slice must be live");

    // Read the live line, then shove BOTH endpoints +0.25 along X via the panel
    // so the whole cut plane translates along X (still crossing the cube, still
    // 12v/10f, but at a different location). We compare the mean X of the
    // crossing verts before/after to prove the cut MOVED on the attr write.
    auto st0 = getToolState();
    double sx = st0["startX"].floating;
    double ex = st0["endX"].floating;

    double meanXBefore = 0;
    {
        auto vs = getModel()["vertices"].array;
        foreach (v; vs) meanXBefore += v.array[0].floating;
        meanXBefore /= vs.length;
    }

    // Translate the line +0.25 along X. If the line is X-aligned this changes
    // its length (still a valid cut); if it's Z-aligned it moves the cut plane
    // along X — either way the resulting geometry must change.
    cmd(format("tool.attr mesh.sliceTool startX %g", sx + 0.25));
    settle();
    cmd(format("tool.attr mesh.sliceTool endX %g", ex + 0.25));
    settle();

    double meanXAfter = 0;
    {
        auto vs = getModel()["vertices"].array;
        foreach (v; vs) meanXAfter += v.array[0].floating;
        meanXAfter /= vs.length;
    }

    assert(fabs(meanXAfter - meanXBefore) > 1e-4,
           format("panel endpoint edit (startX/endX +0.25) must move the CURRENT " ~
                  "cut immediately (mean X %.5f -> %.5f)", meanXBefore, meanXAfter));

    cmd("tool.set mesh.sliceTool off");
    settle();
}

// ---------------------------------------------------------------------------
// `fast` does NOT block a panel edit: with Fast Slice ON, a deliberate param
// edit still re-previews the current slice immediately (fast only gates the
// live DRAG recompute). Editing `fast` itself must not toggle geometry.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    assert(vertCount() == 8 && faceCount() == 6, "fresh cube must be 8v/6f");

    Vec3 lineAxis;
    sliceOnceLeaveActive(lineAxis);
    assert(vertCount() == 12 && faceCount() == 10, "mid-plane slice must be live");

    // Turn Fast ON — must NOT change the geometry (it is not cut-affecting).
    cmd("tool.attr mesh.sliceTool fast 1");
    settle();
    assert(vertCount() == 12 && faceCount() == 10,
           format("editing `fast` must not toggle geometry, got %dv/%df",
                  vertCount(), faceCount()));
    assert(getToolState()["fast"].boolean == true, "fast attr must be set");

    // Now edit `split` WHILE fast is on — the current slice must STILL re-cut
    // immediately (a panel edit is not a drag; fast only gates the live drag).
    cmd("tool.attr mesh.sliceTool split 1");
    settle();
    assert(vertCount() > 12,
           format("panel `split 1` must re-cut immediately even with fast ON, got %dv",
                  vertCount()));

    cmd("tool.set mesh.sliceTool off");
    settle();
}
