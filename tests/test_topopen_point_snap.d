// Topology Pen — Point placement reads the snap election (task 9501).
//
// A Point-mode click over a background mesh lands on the snap election's
// answer when snapping is on: the NEAREST vertex in the snap range from ANY
// background polygon, not the hit polygon's own nearest corner. With
// snapping off it lands on the surface under the press. Captured law: the
// private K-P cells P8 (snap on) / P8c (snap off).
//
// Rig (front view, plane z = 0, sizes in screen px at the focus depth):
//   F1 = A B C D, the polygon under the press; its corner A is 7 px away.
//   F2, F3 sit below F1 and share M, a T-vertex on F1's bottom side that is
//   NOT a corner of F1, 3 px from the press.
// The hit-face-only answer would be A; the election's is M.
//
// Run via: ./run_test.d topopen_point_snap

import topopen_place_helpers;
import http_command_helpers : commandBody;
import std.json;
import std.format : format;
import std.math   : abs;

void main() {}

/// Press, the front camera and the background built around the press's own
/// pixel-centre hit. Returns the press pixel, the press hit and M.
void setupRig(out int px, out int py, out Vec3 pressW, out Vec3 mW) {
    postJson("/api/command", commandBody("scene.reset"));
    enum string camBody =
        `{"azimuth":0.0,"elevation":0.0,"distance":4.0,"focus":{"x":0.0,"y":0.0,"z":0.0}}`;
    postJson("/api/camera", camBody);
    auto c  = fetchCamera();
    auto vp = viewportFromCamera(c);
    px = c.vpX + c.width / 2;
    py = c.vpY + c.height / 2;

    // px per world unit on z = 0 (fronto-parallel, so the scale is uniform).
    float ox, oy, ux, uy;
    assert(projectToWindow(Vec3(0, 0, 0), vp, ox, oy)
        && projectToWindow(Vec3(1, 0, 0), vp, ux, uy), "setup: the plane must project");
    immutable float u = 1.0f / (ux - ox);
    assert(u > 0.0f && u < 0.05f, format("setup: implausible world/px %s", u));

    // The CONS hit samples the pixel centre.
    Vec3 dir = screenRay(px + 0.5f, py + 0.5f, vp);
    immutable float t = -c.eye.z / dir.z;
    pressW = Vec3(c.eye.x + dir.x * t, c.eye.y + dir.y * t, 0.0f);

    Vec3 at(float x, float y) { return Vec3(pressW.x + x * u, pressW.y + y * u, 0.0f); }
    const Vec3[] v = [at(-6.5f, -2.6f) /*0 A*/, at(30, -2.6f) /*1 B*/, at(30, 30) /*2 C*/,
                      at(-6.5f, 30) /*3 D*/, at(1.5f, -2.6f) /*4 M*/, at(-6.5f, -30) /*5*/,
                      at(1.5f, -30) /*6*/, at(30, -30) /*7*/];
    mW = v[4];
    JSONValue[] va;
    foreach (p; v) va ~= JSONValue([p.x, p.y, p.z]);
    JSONValue body = JSONValue.emptyObject;
    body["vertices"] = JSONValue(va);
    body["faces"]    = parseJSON(`[[0,1,2,3],[0,5,6,4],[4,6,7,1]]`);
    auto lr = postJson("/api/command", commandBody("scene.loadMesh", body.toString));
    assert(lr["status"].str == "ok", "load-mesh failed: " ~ lr.toString);
    cmd("layer.add name:Edit");
    postJson("/api/camera", camBody);   // a load restores its own camera
    auto c2 = fetchCamera();
    assert(c2.eye.z == c.eye.z && c2.width == c.width, "setup: the camera must be the rig's");
    assert(vertexCountLayer(1) == 0, "setup: the primary layer must start empty");

    cmd("tool.set mesh.topoPen on");
    cmd("tool.attr mesh.topoPen mode point");
}

Vec3 placeAndRead(int px, int py) {
    auto c = fetchCamera();
    auto pr = postJson("/api/play-events", clickLog(c.vpX, c.vpY, c.width, c.height, px, py));
    assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
    waitPlayerIdle();
    assert(vertexCountLayer(1) == 1,
        format("exactly one vertex must be placed; got %d", vertexCountLayer(1)));
    auto v = readVerticesLayer(1)[0];
    return Vec3(cast(float)v[0], cast(float)v[1], cast(float)v[2]);
}

float dist(Vec3 a, Vec3 b) { Vec3 d = a - b; return dot(d, d) ^^ 0.5f; }

unittest { // P8: snapping on (vertex) — the point lands exactly on M.
    int px, py; Vec3 pressW, mW;
    setupRig(px, py, pressW, mW);
    cmd("tool.pipe.attr snap enabled true");
    cmd("tool.pipe.attr snap types vertex");
    immutable Vec3 got = placeAndRead(px, py);
    assert(dist(got, mW) < 1e-5f,
        format("with vertex snapping on the placed point must be the background T-vertex M %s "
             ~ "(the nearest vertex of ANY polygon); got %s, press hit %s", mW, got, pressW));
}

unittest { // P8c: snapping off — the point lands on the press's surface hit.
    int px, py; Vec3 pressW, mW;
    setupRig(px, py, pressW, mW);
    cmd("tool.pipe.attr snap enabled false");
    immutable Vec3 got = placeAndRead(px, py);
    assert(dist(got, pressW) < 1e-4f,
        format("with snapping off the placed point must be the press hit %s; got %s (M %s)",
               pressW, got, mW));
}
