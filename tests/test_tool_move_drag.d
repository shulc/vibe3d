// Interactive move-tool drag test (Stage A1 of doc/test_coverage_plan.md).
//
// What this exercises end-to-end:
//   1. select vertex 6 (cube corner (0.5,0.5,0.5))
//   2. tool.set move — gizmo appears at ACEN.Auto pivot = v6
//   3. play a synthesized MOUSEBUTTONDOWN + N motion + UP sequence
//      onto the X-arrow handle; events flow through the live SDL/tool
//      pipeline, not /api/transform — so the test pins the entire
//      hit-test → axisDragDelta → applyDelta path that the UI uses.
//   4. /api/model verifies v6 moved in +X and stayed put in Y/Z; all
//      other cube vertices are untouched.
//
// Task 0234 (M3): the press point comes from `/api/tool/handles` part 0
// (the X-move arrow — MOVE_BASE+0, source/tools/move.d:registerHandles) —
// the tool's OWN serialization of its OWN gizmo geometry — instead of this
// test reconstructing `ShaftedArrow` start/end offsets (size/6, size*1.18…)
// by hand. The DRAG DIRECTION still comes from projecting the world +X
// pivot offset (`/api/tool/state`'s `pivot` + a world-space nudge) — that
// part isn't semantic, it's just "which way is +X on screen right now",
// and turning that into data too is a follow-up (see the plan's note on
// rotate/scale drag-by-part needing a rim point, not a center).

import std.net.curl;
import std.json;
import std.math : fabs, sqrt;
import std.conv : to;

import drag_helpers;

void main() {}

bool approx(double a, double b, double eps = 1e-3) { return fabs(a - b) < eps; }

unittest { // X-axis drag of v6 only moves v6 in +X
    post("http://localhost:8080/api/reset", "");

    auto selResp = post("http://localhost:8080/api/select",
                        `{"mode":"vertices","indices":[6]}`);
    assert(parseJSON(cast(string)selResp)["status"].str == "ok",
        "select failed: " ~ cast(string)selResp);

    auto setResp = post("http://localhost:8080/api/script", "tool.set move");
    assert(parseJSON(cast(string)setResp)["status"].str == "ok",
        "tool.set move failed: " ~ cast(string)setResp);

    auto pre6 = vertexPos(6);
    auto pre0 = vertexPos(0);
    auto pre7 = vertexPos(7);

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    // /api/tool/handles only reflects the gizmo AFTER a draw() frame has run
    // (it registers `toolHandles.entries` + sets `cachedVp`) — settle before
    // fetching so part 0 is actually present; fail loud (assert) rather than
    // retry-loop, so a real regression (numbering shift, gizmo never drawn)
    // surfaces as a clear failure instead of a flaky timeout.
    import core.thread : Thread;
    import core.time   : msecs;
    Thread.sleep(150.msecs);

    double sx0, sy0;
    bool found;
    fetchHandlePart(0, sx0, sy0, found);
    assert(found, "X-move handle (part 0) not found in /api/tool/handles — " ~
        "gizmo numbering or draw timing regressed");
    int x0 = cast(int)sx0;
    int y0 = cast(int)sy0;

    // ACEN.Auto with single-vertex selection ⇒ gizmo pivot = v6. Project the
    // pivot itself + a small +X world nudge to recover the on-screen drag
    // DIRECTION (not the click point — that came from the handle above).
    Vec3 pivot = Vec3(0.5f, 0.5f, 0.5f);
    float sxPivot, syPivot, sxNudge, syNudge;
    assert(projectToWindow(pivot, vp, sxPivot, syPivot),
        "pivot projects off-camera");
    assert(projectToWindow(Vec3(pivot.x + 1.0f, pivot.y, pivot.z), vp, sxNudge, syNudge),
        "pivot+X projects off-camera");

    // Drag ~100 px along the on-screen projection of the world X-axis.
    // Magnitude chosen so the world delta is comfortably > 0.1 regardless
    // of camera aspect — tiny layout drift won't shrink the actual move
    // below the 0.1 lower-bound assertion.
    double sdx = cast(double)(sxNudge - sxPivot);
    double sdy = cast(double)(syNudge - syPivot);
    double sLen = sqrt(sdx*sdx + sdy*sdy);
    assert(sLen > 1.0,
        "world +X projects too short to drive a robust drag (camera bad?)");
    int x1 = x0 + cast(int)(100.0 * sdx / sLen);
    int y1 = y0 + cast(int)(100.0 * sdy / sLen);

    string log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              x0, y0, x1, y1, 20);
    playAndWait(log);

    auto post6 = vertexPos(6);
    auto post0 = vertexPos(0);
    auto post7 = vertexPos(7);

    double dx = post6[0] - pre6[0];
    double dy = post6[1] - pre6[1];
    double dz = post6[2] - pre6[2];
    // X-arrow drag must be a pure +X translation. Lower-bound 0.1 keeps
    // the test honest about whether the drag actually fired — anything
    // smaller usually means hit-test missed the shaft.
    assert(dx > 0.1,
        "v6.x should grow with +X drag: dx=" ~ dx.to!string ~
        " (pre.x=" ~ pre6[0].to!string ~ " post.x=" ~ post6[0].to!string ~ ")");
    assert(approx(dy, 0.0, 0.01),
        "v6.y should not change in X-only drag: dy=" ~ dy.to!string);
    assert(approx(dz, 0.0, 0.01),
        "v6.z should not change in X-only drag: dz=" ~ dz.to!string);

    // Unselected vertices must stay put.
    foreach (k; 0 .. 3) {
        assert(approx(post0[k], pre0[k], 1e-4),
            "v0 moved on X-arrow drag of v6 (component " ~ k.to!string ~ ")");
        assert(approx(post7[k], pre7[k], 1e-4),
            "v7 moved on X-arrow drag of v6 (component " ~ k.to!string ~ ")");
    }
}
