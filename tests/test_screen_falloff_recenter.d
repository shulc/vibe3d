// Screen falloff must re-center at the click DURING the drag
// (regression for the "re-center screen falloff at the click during the drag"
// fix in source/tools/transform.d captureFalloffForDrag).
//
// Root cause: app.d (buildToolVts) evaluates the pipeline and snapshots the
// FalloffPacket into the tool's VectorStack BEFORE the tool runs.
// MoveTool.onMouseButtonDown then re-centers the screen disc at the click
// (screenFalloffSetCenter → the live FalloffStage), which happens AFTER that
// snapshot. captureFalloffForDrag froze the PREVIOUS center for the whole
// drag, so the disc deformed the geometry around the PREVIOUS click and only
// caught up on the next eval at mouse-up. The fix refreshes the captured
// drag-falloff screen center from the live stage so the disc is anchored at
// THIS click for the whole drag.
//
// Because the bug self-corrects on release (the release re-eval reads the new
// center), the assertion MUST observe geometry MID-DRAG with the drag left
// OPEN (no mouse-up).
//
// Repro:
//   * Reset, subdivide twice → a dense (~98-vert) mesh so the screen disc
//     selects a clear, localized cluster.
//   * tool.set move; falloff.screen; screenSize 70.
//   * Project every vert; pick P1 = projection of the left-most vert, P2 =
//     projection of the right-most vert (clearly separated, off the small
//     center gizmo).
//   * Drag 1 at P1 (full drag WITH release). This leaves the live stage's
//     screen center at P1.
//   * Drag 2 at P2 but LEAVE IT OPEN (down + motions, NO mouse-up). Read the
//     mid-drag geometry.
//   * The verts that move most during drag 2 must be the ones whose ORIGINAL
//     projection is nearest P2 — NOT P1. Pre-fix the top-moved verts were the
//     near-P1 cluster (stale center). We assert the single most-moved vert is
//     within the near-P2 set (nearest-3 to P2) and is NOT in the near-P1 set
//     (nearest-3 to P1). Indices are computed from projections, never
//     hardcoded.
//   * Release cleanly afterward.

import std.net.curl;
import std.json;
import std.math : fabs, sqrt;
import std.conv : to;
import std.string : format;
import std.algorithm : sort, canFind, map;
import std.array : array;

import drag_helpers;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(baseUrl ~ path, body_));
}
JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

void settle() {
    import core.thread : Thread;
    import core.time   : msecs;
    Thread.sleep(150.msecs);
}

Vec3[] allVerts() {
    Vec3[] out_;
    foreach (v; getJson("/api/model")["vertices"].array) {
        auto a = v.array;
        out_ ~= Vec3(cast(float)a[0].floating,
                     cast(float)a[1].floating,
                     cast(float)a[2].floating);
    }
    return out_;
}

// Build an OPEN drag log: VIEWPORT + down + N motions, NO mouse-up. Motions are
// spaced 50ms apart (same cadence as buildDragLog) so each lands in its own
// frame instead of being coalesced.
string openDragLog(int vpX, int vpY, int vpW, int vpH,
                   int x0, int y0, int x1, int y1, int steps) {
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        vpX, vpY, vpW, vpH);
    double tDown = 50.0;
    log ~= format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        tDown, x0, y0);
    int lastX = x0, lastY = y0;
    foreach (i; 1 .. steps + 1) {
        int x = x0 + cast(int)((cast(double)(x1 - x0) * i) / steps);
        int y = y0 + cast(int)((cast(double)(y1 - y0) * i) / steps);
        double t = tDown + i * 50.0;
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
            t, x, y, x - lastX, y - lastY);
        lastX = x; lastY = y;
    }
    return log;
}

string mouseUpLog(int vpX, int vpY, int vpW, int vpH, int x, int y) {
    return format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~
        `{"t":50.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        vpX, vpY, vpW, vpH, x, y);
}

unittest {
    // ---- Build a dense mesh ----
    postJson("/api/reset", "");
    // Whole-cage subdivide (no face selection in vertices mode) twice → ~98
    // verts. The screen disc then selects a clear local cluster.
    postJson("/api/script", "mesh.subdivide\nmesh.subdivide");
    settle();
    auto base = allVerts();
    assert(base.length > 50,
        "expected a dense mesh (>50 verts) after two subdivides; got " ~
        base.length.to!string);

    // ---- Configure move + screen falloff ----
    postJson("/api/script", "tool.set move\nfalloff.screen");
    postJson("/api/command", "tool.pipe.attr falloff screenSize 70");
    settle();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    // ---- Project every vert; pick P1 (left-most) and P2 (right-most) ----
    float[2][] proj;   // window-pixel projection per vert index
    proj.length = base.length;
    foreach (i, v; base) {
        float px, py;
        assert(projectToWindow(v, vp, px, py),
            "vert " ~ i.to!string ~ " off-camera");
        proj[i] = [px, py];
    }
    size_t leftIdx = 0, rightIdx = 0;
    foreach (i; 0 .. proj.length) {
        if (proj[i][0] < proj[leftIdx][0])  leftIdx  = i;
        if (proj[i][0] > proj[rightIdx][0]) rightIdx = i;
    }
    float[2] P1 = proj[leftIdx];
    float[2] P2 = proj[rightIdx];

    double sep = sqrt(cast(double)((P1[0] - P2[0]) * (P1[0] - P2[0]) +
                                   (P1[1] - P2[1]) * (P1[1] - P2[1])));
    assert(sep > 80.0,
        "P1 (left-most vert proj) and P2 (right-most) must be clearly " ~
        "separated to exercise the re-center; got sep=" ~ sep.to!string);

    // ---- Helper: indices sorted by 2D distance of ORIGINAL proj to a point ---
    size_t[] nearestTo(float[2] p) {
        auto idx = new size_t[proj.length];
        foreach (i; 0 .. proj.length) idx[i] = i;
        sort!((a, b) {
            double da = (proj[a][0]-p[0])*(proj[a][0]-p[0]) +
                        (proj[a][1]-p[1])*(proj[a][1]-p[1]);
            double db = (proj[b][0]-p[0])*(proj[b][0]-p[0]) +
                        (proj[b][1]-p[1])*(proj[b][1]-p[1]);
            return da < db;
        })(idx);
        return idx;
    }
    auto nearP1 = nearestTo(P1)[0 .. 3];
    auto nearP2 = nearestTo(P2)[0 .. 3];

    // ---- Drag 1 at P1 (full drag WITH release) ----
    int p1x = cast(int)P1[0], p1y = cast(int)P1[1];
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             p1x, p1y, p1x, p1y - 25, 10));
    settle();
    auto afterDrag1 = allVerts();
    assert(afterDrag1.length == base.length, "vert count changed across drag 1");

    // ---- Drag 2 at P2 — LEFT OPEN (no mouse-up) ----
    int p2x = cast(int)P2[0], p2y = cast(int)P2[1];
    playAndWait(openDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                            p2x, p2y, p2x, p2y - 25, 10));
    settle();
    auto midDrag2 = allVerts();
    assert(midDrag2.length == base.length, "vert count changed across drag 2");

    // ---- Per-vertex displacement DURING drag 2 ----
    double d2(size_t i) {
        auto a = afterDrag1[i], b = midDrag2[i];
        return sqrt(cast(double)((b.x-a.x)*(b.x-a.x) +
                                 (b.y-a.y)*(b.y-a.y) +
                                 (b.z-a.z)*(b.z-a.z)));
    }
    // Most-moved vert during the OPEN drag 2.
    size_t topMoved = 0;
    foreach (i; 0 .. midDrag2.length)
        if (d2(i) > d2(topMoved)) topMoved = i;

    assert(d2(topMoved) > 1e-3,
        "drag 2 should move at least one vert (open drag at P2 produced no " ~
        "motion); max d2=" ~ d2(topMoved).to!string);

    // THE assertion: the mid-drag motion must be centered on P2, not P1.
    // Post-fix the most-moved vert is in the near-P2 cluster; pre-fix (stale
    // screen center) it was in the near-P1 cluster.
    assert(nearP2.canFind(topMoved),
        "during the OPEN drag at P2 the most-moved vert (" ~ topMoved.to!string ~
        ") must be one of the verts nearest P2 (" ~ nearP2.to!string ~
        "); pre-fix the screen disc stayed stale at P1");
    assert(!nearP1.canFind(topMoved),
        "during the OPEN drag at P2 the most-moved vert (" ~ topMoved.to!string ~
        ") must NOT be in the near-P1 cluster (" ~ nearP1.to!string ~
        ") — that would mean the screen falloff is still centered at the " ~
        "previous click (the bug)");

    // ---- Release cleanly ----
    playAndWait(mouseUpLog(cam.vpX, cam.vpY, cam.width, cam.height,
                           p2x, p2y - 25));
    settle();
}
