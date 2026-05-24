// Regression test: chained move-tool drags within one tool session
// must keep the GPU view (gpu.faceVbo × gpuMatrix) consistent with the
// CPU mesh state mid-drag.
//
// User-reported bug: drag the XY-plane circle, release; press LMB on
// the X-arrow and start dragging — the cube renders displaced from the
// gizmo, with the offset matching the FIRST drag's delta. Visually the
// mesh "jumps" by that delta until the second drag finishes (mouseUp
// uploads CPU vertices, gpuMatrix resets, the displacement vanishes).
//
// Mechanism: MoveTool sets `gpuMatrix = translationMatrix(dragDelta)`
// on every motion of a whole-mesh drag. `dragDelta` is tool-session-
// cumulative (Phase 7.5h) — i.e. the first drag's delta survives into
// the second drag's edit session. But the GPU VBO uploaded at the
// first drag's mouseUp already bakes in deltaA, so the renderer applies
// (orig + deltaA) × translation(deltaA + deltaB) = orig + 2·deltaA + deltaB,
// while the CPU mesh sits at orig + deltaA + deltaB.
//
// This test catches the discrepancy by pausing playback mid-second-drag
// (no mouseUp in the event log) and comparing `model · gpu.faceVbo` to
// `/api/model`.

import std.net.curl;
import std.json;
import std.math : fabs, sqrt;
import std.conv : to;
import std.format : format;

import drag_helpers;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(baseUrl ~ path, body_));
}
JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

void waitPlaybackFinish() {
    import core.thread : Thread;
    import core.time   : msecs;
    foreach (_; 0 .. 200) {
        auto j = getJson("/api/play-events/status");
        if (j["finished"].type == JSONType.TRUE) return;
        Thread.sleep(50.msecs);
    }
    assert(false, "playback didn't finish within 10s");
}

bool approx(double a, double b, double eps = 1e-3) { return fabs(a - b) < eps; }

// Build an event log for one tool-session drag. `release` controls
// whether the trailing MOUSEBUTTONUP fires — set false to leave the
// tool mid-drag so the test can observe gpu-vs-cpu mid-flight.
string buildPartialDragLog(int vpX, int vpY, int vpW, int vpH,
                            int x0, int y0, int x1, int y1,
                            int steps, bool release, double tStart = 50.0)
{
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        vpX, vpY, vpW, vpH);
    log ~= format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        tStart, x0, y0);
    double stepMs = 50.0;
    int lastX = x0, lastY = y0;
    foreach (i; 1 .. steps + 1) {
        int x = x0 + cast(int)((cast(double)(x1 - x0) * i) / steps);
        int y = y0 + cast(int)((cast(double)(y1 - y0) * i) / steps);
        double t = tStart + i * stepMs;
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
            t, x, y, x - lastX, y - lastY);
        lastX = x; lastY = y;
    }
    if (release) {
        double tUp = tStart + (steps + 1) * stepMs;
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
            tUp, x1, y1);
    }
    return log;
}

// Multiply a 16-element column-major matrix by a (x,y,z,1) point.
double[3] applyModel(double[16] m, double x, double y, double z) {
    double rx = m[0]*x + m[4]*y + m[8]*z  + m[12];
    double ry = m[1]*x + m[5]*y + m[9]*z  + m[13];
    double rz = m[2]*x + m[6]*y + m[10]*z + m[14];
    return [rx, ry, rz];
}

unittest { // After drag1+drag2 in one tool session, rendered position = CPU mesh
    postJson("/api/reset", "");
    postJson("/api/select",
        `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`);
    postJson("/api/script", "tool.set move");

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    // Drag 1: XY-plane circle (handler.circleXY sits at +X +Y corner of
    // the gizmo basis quad — same pickable surface that triggers
    // dragAxis==4 in MoveTool.hitTestAxes).
    Vec3 pivot = Vec3(0, 0, 0);
    float size = gizmoSize(pivot, vp);
    Vec3 circleCenter = Vec3(pivot.x + size * 0.75f,
                              pivot.y + size * 0.75f,
                              pivot.z);
    float cx, cy;
    assert(projectToWindow(circleCenter, vp, cx, cy),
        "XY circle off-camera");
    int x0a = cast(int)cx, y0a = cast(int)cy;
    int x1a = x0a, y1a = y0a + 50;    // screen-down ~50 px
    string log1 = buildPartialDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                       x0a, y0a, x1a, y1a, 10, /*release=*/true);
    auto r1 = postJson("/api/play-events", log1);
    assert(r1["status"].str == "success", "drag1 play-events failed");
    waitPlaybackFinish();

    // Drag 1's mouseUp triggers gpu.upload + gpuMatrix reset, so at this
    // point CPU and GPU agree. Sanity-check before staging drag 2.
    auto cpu1 = getJson("/api/model")["vertices"].array;
    auto gpu1 = getJson("/api/gpu/face-vbo");
    auto m1 = gpu1["model"].array;
    foreach (i; 0 .. 16) {
        double expected = (i == 0 || i == 5 || i == 10 || i == 15) ? 1.0 : 0.0;
        assert(approx(m1[i].floating, expected, 1e-5),
            "after drag1 mouseUp, gpuMatrix should be identity, got [" ~
            i.to!string ~ "]=" ~ m1[i].floating.to!string);
    }

    // Drag 2: X-arrow, NO mouseUp (truncated log). After this the tool
    // is mid-drag — dragAxis==0, gpuMatrix scaled by the tool-session
    // dragDelta. The bug shows up here.
    auto cam2 = fetchCamera();
    auto vp2  = viewportFromCamera(cam2);
    // Re-derive pivot from current selection centroid (CPU mesh has
    // already moved by drag1's delta).
    Vec3 pivot2 = Vec3(0, 0, 0);
    foreach (v; cpu1) {
        pivot2.x += cast(float)v.array[0].floating;
        pivot2.y += cast(float)v.array[1].floating;
        pivot2.z += cast(float)v.array[2].floating;
    }
    pivot2 = Vec3(pivot2.x / 8.0f, pivot2.y / 8.0f, pivot2.z / 8.0f);
    float size2 = gizmoSize(pivot2, vp2);
    Vec3 arrowStart = Vec3(pivot2.x + size2 / 6.0f, pivot2.y, pivot2.z);
    Vec3 arrowEnd   = Vec3(pivot2.x + size2,         pivot2.y, pivot2.z);
    float sx1, sy1, sx2, sy2;
    assert(projectToWindow(arrowStart, vp2, sx1, sy1), "X-arrow start off-camera");
    assert(projectToWindow(arrowEnd,   vp2, sx2, sy2), "X-arrow end off-camera");
    int x0b = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    int y0b = cast(int)(sy1 + 0.7f * (sy2 - sy1));
    double sdx = cast(double)(sx2 - sx1);
    double sdy = cast(double)(sy2 - sy1);
    double sLen = sqrt(sdx*sdx + sdy*sdy);
    int x1b = x0b + cast(int)(60.0 * sdx / sLen);
    int y1b = y0b + cast(int)(60.0 * sdy / sLen);
    string log2 = buildPartialDragLog(cam2.vpX, cam2.vpY, cam2.width, cam2.height,
                                       x0b, y0b, x1b, y1b, 10, /*release=*/false);
    auto r2 = postJson("/api/play-events", log2);
    assert(r2["status"].str == "success", "drag2 play-events failed");
    waitPlaybackFinish();

    // Now: tool is mid-drag. CPU mesh has both drag1 and drag2 deltas
    // applied. GPU.faceVbo has only drag1's (last uploaded at drag1
    // mouseUp). gpuMatrix should translate by ONLY drag2's incremental
    // delta — not the tool-session cumulative.
    auto cpu2 = getJson("/api/model")["vertices"].array;
    auto gpu2 = getJson("/api/gpu/face-vbo");
    auto m2   = gpu2["model"].array;

    double[16] model;
    foreach (i; 0 .. 16) model[i] = m2[i].floating;

    auto positions = gpu2["positions"].array;
    long faceVerts = gpu2["faceVertCount"].integer;
    assert(faceVerts > 0, "GPU has no face verts");

    // Re-derive a per-cube-vert visual position by transforming the GPU
    // buffer through the model matrix. For a cube, every cube vert (0..7)
    // shows up multiple times in faceVbo (6 faces × 2 tris × 3 verts =
    // 36 face-verts). For each one we test that the transformed GPU pos
    // matches the CPU mesh vert at the SAME world coordinates as one of
    // the 8 cube verts.
    foreach (i; 0 .. faceVerts) {
        auto p = positions[i].array;
        double gx = p[0].floating;
        double gy = p[1].floating;
        double gz = p[2].floating;
        auto visual = applyModel(model, gx, gy, gz);

        // Find the CPU mesh vert closest to `visual`. If they truly
        // match, the closest CPU vert sits within rounding distance.
        double bestD2 = double.max;
        int bestI = -1;
        foreach (vi, v; cpu2) {
            double dx = v.array[0].floating - visual[0];
            double dy = v.array[1].floating - visual[1];
            double dz = v.array[2].floating - visual[2];
            double d2 = dx*dx + dy*dy + dz*dz;
            if (d2 < bestD2) { bestD2 = d2; bestI = cast(int)vi; }
        }
        assert(bestD2 < 1e-4,
            "GPU-rendered face-vert " ~ i.to!string ~ " = (" ~
            visual[0].to!string ~ "," ~ visual[1].to!string ~ "," ~
            visual[2].to!string ~ ") doesn't match any CPU mesh vert " ~
            "within 1e-4 (closest: v" ~ bestI.to!string ~
            " distance²=" ~ bestD2.to!string ~ "). Likely cause: " ~
            "MoveTool's gpuMatrix carries the tool-session cumulative " ~
            "dragDelta when it should carry only the current drag's " ~
            "delta — the previous drag's delta is already baked into " ~
            "gpu.faceVbo from its mouseUp upload.");
    }

    // Cleanly close out the tool session so subsequent tests start fresh
    // (the dangling mid-drag would leak otherwise).
    postJson("/api/script", "tool.set move off");
}
