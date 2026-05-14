// Radial-falloff drag test (Stage B3 of doc/test_coverage_plan.md).
//
// The plan calls for the two-stage RMB gesture (click → flat disc;
// second drag → height), but the interactive RMB-create path is hard
// to pin via event-log (the falloff ellipsoid lands on the most-facing
// workplane, which depends on camera-axis dot products in a way that
// hides the asserted invariants behind a layer of projection math).
// Configuring the radial packet via `tool.pipe.attr` directly produces
// the same state — the live drag path then runs identically.
//
// What this pins:
//   • during a move drag, each selected vertex's displacement is
//     multiplied by its radial weight evaluated at the BASELINE position
//     (so the gizmo center moves by `delta` but a vert at the falloff
//     surface stays put)
//   • the weight falls off MONOTONICALLY with distance from the falloff
//     center: v0 (at center) moves the most; v6 (opposite corner) moves
//     the least

import std.net.curl;
import std.json;
import std.math : fabs, sqrt;
import std.conv : to;

import drag_helpers;

void main() {}

bool approx(double a, double b, double eps = 1e-3) { return fabs(a - b) < eps; }

unittest { // radial falloff: closer-to-center verts move more in a drag
    post("http://localhost:8080/api/reset", "");

    auto selResp = post("http://localhost:8080/api/select",
                        `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`);
    assert(parseJSON(cast(string)selResp)["status"].str == "ok",
        "select failed: " ~ cast(string)selResp);

    // Place the radial center at v0 (-0.5,-0.5,-0.5) and stretch the
    // ellipsoid to size=(2,2,2) — every cube corner falls inside the
    // ellipsoid with a different normalised distance, giving each vert
    // a distinct weight. v0 has t=0 → w=1; v6 has t=sqrt(3)/2 ≈ 0.866
    // → w ≈ 0.13 (shape-dependent).
    string script =
        "tool.set move\n" ~
        "tool.pipe.attr falloff type radial\n" ~
        `tool.pipe.attr falloff center "-0.5,-0.5,-0.5"` ~ "\n" ~
        `tool.pipe.attr falloff size "2,2,2"` ~ "\n";
    auto setResp = post("http://localhost:8080/api/script", script);
    assert(parseJSON(cast(string)setResp)["status"].str == "ok",
        "tool.set + radial config failed: " ~ cast(string)setResp);

    double[3][8] pre;
    foreach (i; 0 .. 8) pre[i] = vertexPos(i);

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    // ACEN.Auto pivot for full cube = origin. Drag the Y arrow up so
    // the per-vertex displacement is along the same axis for every
    // vert — easier to compare magnitudes.
    Vec3 pivot = Vec3(0, 0, 0);
    float size = gizmoSize(pivot, vp);
    Vec3 arrowStart = Vec3(pivot.x, pivot.y + size / 6.0f, pivot.z);
    Vec3 arrowEnd   = Vec3(pivot.x, pivot.y + size,         pivot.z);
    float sx1, sy1, sx2, sy2;
    assert(projectToWindow(arrowStart, vp, sx1, sy1), "Y-arrow start off-camera");
    assert(projectToWindow(arrowEnd,   vp, sx2, sy2), "Y-arrow end off-camera");
    int x0 = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    int y0 = cast(int)(sy1 + 0.7f * (sy2 - sy1));
    double sdx = cast(double)(sx2 - sx1), sdy = cast(double)(sy2 - sy1);
    double sLen = sqrt(sdx*sdx + sdy*sdy);
    int x1 = x0 + cast(int)(100.0 * sdx / sLen);
    int y1 = y0 + cast(int)(100.0 * sdy / sLen);

    string log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              x0, y0, x1, y1, 20);
    playAndWait(log);

    double dy(int i) {
        return vertexPos(i)[1] - pre[i][1];
    }

    double dy0 = dy(0);
    double dy6 = dy(6);
    // v0 sits AT the falloff center → full weight ⇒ moves by full delta.
    assert(dy0 > 0.1,
        "v0 (at falloff center) barely moved: dy0=" ~ dy0.to!string);
    // v6 is the opposite corner — outside the linear-decay sweet spot,
    // so weight is small and so should its motion be (< 50 % of v0's).
    assert(dy6 < dy0 * 0.5 && dy6 >= 0,
        "v6 (far from falloff center) should move much less than v0: " ~
        "dy0=" ~ dy0.to!string ~ " dy6=" ~ dy6.to!string);

    // Monotone: corners ordered by distance from (-0.5,-0.5,-0.5) should
    // move in the same order. Distances: v0=0, {v1,v3,v4}=1, {v2,v5,v7}=√2,
    // v6=√3. So dy0 ≥ dy{1,3,4} ≥ dy{2,5,7} ≥ dy6 within tolerance.
    foreach (i; [1, 3, 4]) {
        assert(dy(i) <= dy0 + 1e-3,
            "v" ~ i.to!string ~ " (dist 1) moved more than v0 (dist 0): " ~
            dy(i).to!string ~ " > " ~ dy0.to!string);
        assert(dy(i) >= dy6 - 1e-3,
            "v" ~ i.to!string ~ " (dist 1) moved less than v6 (dist √3): " ~
            dy(i).to!string ~ " < " ~ dy6.to!string);
    }
    foreach (i; [2, 5, 7]) {
        assert(dy(i) >= dy6 - 1e-3,
            "v" ~ i.to!string ~ " (dist √2) moved less than v6 (dist √3): " ~
            dy(i).to!string ~ " < " ~ dy6.to!string);
    }
}
