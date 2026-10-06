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
// A third cell scales the rig by 10: M at 30 px is gathered (40) but not
// accepted (24), so the point stays on the press hit.
// K-PS cells: an EDITED vertex is a snap target too (a coincident duplicate,
// no weld), with the same 24 px acceptance.
//
// Run via: ./run_test.d topopen_point_snap

import topopen_place_helpers;
import http_command_helpers : commandBody;
import std.json;
import std.format : format;
import std.math   : abs;


void main() {}

Vec3[] dummyQ;

/// Press, the front camera and the background built around the press's own
/// pixel-centre hit. Returns the press pixel, the press hit and M.
/// `k` scales every offset (k = 10 puts M at 30 px: gathered, not accepted).
/// `quad`: also load an EDITED quad whose corner `v` sits 15 px (-12,-9) from the
/// press and whose two sides leave `v` away from it (K-PS KPS_2).
void setupRig(out int px, out int py, out Vec3 pressW, out Vec3 mW, float k = 1.0f,
              bool quad = false, ref Vec3[] q = dummyQ, bool missRig = false) {
    postJson("/api/command", commandBody("scene.reset"));
    enum string camBody =
        `{"azimuth":0.0,"elevation":0.0,"distance":4.0,"focus":{"x":0.0,"y":0.0,"z":0.0}}`;
    const rigCamera = missRig
        ? `{"azimuth":0.0,"elevation":0.0,"distance":4.0,"focus":{"x":2.0,"y":0.0,"z":0.0}}`
        : camBody;
    postJson("/api/camera", rigCamera);
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

    Vec3 at(float x, float y) { return Vec3(pressW.x + x * k * u, pressW.y + y * k * u, 0.0f); }
    const Vec3[] v = [at(-6.5f, -2.6f) /*0 A*/, at(30, -2.6f) /*1 B*/, at(30, 30) /*2 C*/,
                      at(-6.5f, 30) /*3 D*/, at(1.5f, -2.6f) /*4 M*/, at(-6.5f, -30) /*5*/,
                      at(1.5f, -30) /*6*/, at(30, -30) /*7*/];
    mW = v[4];
    JSONValue[] va;
    foreach (p; v) va ~= JSONValue([p.x, p.y, p.z]);
    JSONValue body = JSONValue.emptyObject;
    body["vertices"] = JSONValue(va);
    body["faces"]    = parseJSON(missRig ? `[[0,1,2,3]]` : `[[0,1,2,3],[0,5,6,4],[4,6,7,1]]`);
    auto lr = postJson("/api/command", commandBody("scene.loadMesh", body.toString));
    assert(lr["status"].str == "ok", "load-mesh failed: " ~ lr.toString);
    cmd("layer.add name:Edit");
    if (quad) {
        immutable Vec3 c0 = Vec3(pressW.x - 12 * u, pressW.y + 9 * u, 0.0f);
        q ~= [c0, Vec3(c0.x - 50 * u, c0.y, 0), Vec3(c0.x - 50 * u, c0.y + 50 * u, 0),
              Vec3(c0.x, c0.y + 50 * u, 0)];
        JSONValue[] qa;
        foreach (p; q) qa ~= JSONValue([p.x, p.y, p.z]);
        JSONValue qb = JSONValue.emptyObject;
        qb["vertices"] = JSONValue(qa);
        qb["faces"]    = parseJSON(`[[0,1,2,3]]`);
        auto ql = postJson("/api/command", commandBody("scene.loadMesh", qb.toString));
        assert(ql["status"].str == "ok", "load-mesh (edited quad) failed: " ~ ql.toString);
    }
    postJson("/api/camera", rigCamera);   // a load restores its own camera
    auto c2 = fetchCamera();
    assert(c2.eye.z == c.eye.z && c2.width == c.width, "setup: the camera must be the rig's");
    assert(vertexCountLayer(1) == (quad ? 4 : 0), "setup: the primary layer's start");

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

JSONValue hoverAt(int px, int py) {
    auto c = fetchCamera();
    const motion = viewportLog(c.vpX, c.vpY, c.width, c.height) ~ "\n"
        ~ format(`{"t":10.0,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n", px, py);
    auto reply = postJson("/api/play-events", motion);
    assert("error" !in reply, "hover playback must run");
    waitPlayerIdle();
    return getJson("/api/tool/state")["hover"];
}

float dist(Vec3 a, Vec3 b) { Vec3 d = a - b; return dot(d, d) ^^ 0.5f; }

unittest { // P8: snapping on (vertex) — the point lands exactly on M.
    int px, py; Vec3 pressW, mW;
    setupRig(px, py, pressW, mW);
    cmd("tool.pipe.attr snap enabled true");
    cmd("tool.pipe.attr snap types vertex");
    auto before = hoverAt(px, py);
    assert(before["targetKind"].str == "vertex" && before["targetVert"].integer == 4
        && before["targetSource"].integer == 1,
        "idle election must report background M, not hit-face A: " ~ before.toString);
    immutable Vec3 got = placeAndRead(px, py);
    auto hover = getJson("/api/tool/state")["hover"];
    assert(hover["targetKind"].str == "vertex" && hover["targetVert"].integer == 4
        && hover["targetSource"].integer == 1,
        "election marker/readout must report background M, not hit-face A: " ~ hover.toString);
    assert(dist(got, mW) < 1e-5f,
        format("with vertex snapping on the placed point must be the background T-vertex M %s "
             ~ "(the nearest vertex of ANY polygon); got %s, press hit %s", mW, got, pressW));
}

unittest { // P8c: snapping off — the point lands on the press's surface hit.
    int px, py; Vec3 pressW, mW;
    setupRig(px, py, pressW, mW);
    cmd("tool.pipe.attr snap enabled false");
    auto before = hoverAt(px, py);
    assert(before["targetKind"].str == "face" && before["targetVert"].integer == -1
        && before["targetSource"].integer == -1,
        "disabled idle snapping must have no election target: " ~ before.toString);
    immutable Vec3 got = placeAndRead(px, py);
    auto hover = getJson("/api/tool/state")["hover"];
    assert(hover["targetKind"].str == "face" && hover["targetVert"].integer == -1
        && hover["targetSource"].integer == -1,
        "disabled snapping must have no election marker/readout: " ~ hover.toString);
    assert(dist(got, pressW) < 1e-4f,
        format("with snapping off the placed point must be the press hit %s; got %s (M %s)",
               pressW, got, mW));
}

unittest { // the acceptance reach: M at 30 px (inside the 40 px gather, outside the
           // 24 px acceptance) does not snap — the point lands on the press hit.
    int px, py; Vec3 pressW, mW;
    setupRig(px, py, pressW, mW, 10.0f);
    cmd("tool.pipe.attr snap enabled true");
    cmd("tool.pipe.attr snap types vertex");
    immutable Vec3 got = placeAndRead(px, py);
    assert(dist(got, pressW) < 1e-4f,
        format("a vertex gathered but outside the snap acceptance must not take the point: "
             ~ "press hit %s, got %s (M %s)", pressW, got, mW));
}

/// The world point under pixel centre (x + 0.5, y + 0.5) on z = 0.
Vec3 hitAt(int x, int y) {
    auto c  = fetchCamera();
    auto vp = viewportFromCamera(c);
    Vec3 dir = screenRay(x + 0.5f, y + 0.5f, vp);
    immutable float t = -c.eye.z / dir.z;
    return Vec3(c.eye.x + dir.x * t, c.eye.y + dir.y * t, 0.0f);
}

void clickAtPx(int x, int y) {
    auto c = fetchCamera();
    auto pr = postJson("/api/play-events", clickLog(c.vpX, c.vpY, c.width, c.height, x, y));
    assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
    waitPlayerIdle();
}

Vec3 vertexOf(int layer, size_t i) {
    auto v = readVerticesLayer(layer)[i];
    return Vec3(cast(float)v[0], cast(float)v[1], cast(float)v[2]);
}

// K-PS (private capture): the election's vertex candidates include the EDITED
// mesh. A Point 15 px (+12,-9: away from the rig's M) from an edited vertex
// lands on it as a NEW coincident vertex — no weld (KPS_1, KPS_2); 30 px (+24,-18) is outside the
// 24 px acceptance and lands on the press (KPS_1f). The reference also wraps
// each Point in a one-point polygon; ours makes a bare vertex (gap row 603), so
// polygon counts are pinned only where they do not depend on that.

unittest { // KPS_1: the second Point snaps onto the first — two coincident vertices.
    int px, py; Vec3 pressW, mW;
    setupRig(px, py, pressW, mW, 10.0f);   // no background vertex within 24 px
    cmd("tool.pipe.attr snap enabled true");
    cmd("tool.pipe.attr snap types vertex");
    immutable Vec3 p1 = placeAndRead(px, py);
    assert(dist(p1, pressW) < 1e-4f, format("setup: the first Point must land on its hit %s", p1));
    clickAtPx(px + 12, py - 9);
    assert(vertexCountLayer(1) == 2,
        format("KPS_1: the second Point must ADD a vertex (no weld); got %d", vertexCountLayer(1)));
    immutable Vec3 p2 = vertexOf(1, 1);
    assert(dist(p2, p1) < 1e-5f && dist(vertexOf(1, 0), p1) < 1e-5f,
        format("KPS_1: the second Point must land exactly on the first %s (a coincident duplicate); "
             ~ "got %s, its own hit %s", p1, p2, hitAt(px + 12, py - 9)));
}

unittest { // KPS_1f: 30 px is gathered but not accepted — the second Point lands on its hit.
    int px, py; Vec3 pressW, mW;
    setupRig(px, py, pressW, mW, 10.0f);
    cmd("tool.pipe.attr snap enabled true");
    cmd("tool.pipe.attr snap types vertex");
    immutable Vec3 p1 = placeAndRead(px, py);
    clickAtPx(px + 24, py - 18);
    assert(vertexCountLayer(1) == 2, format("KPS_1f: two vertices expected; got %d", vertexCountLayer(1)));
    immutable Vec3 want = hitAt(px + 24, py - 18);
    assert(dist(vertexOf(1, 1), want) < 1e-4f,
        format("KPS_1f: 30 px from %s is outside the 24 px acceptance; the Point must land on its "
             ~ "hit %s, got %s", p1, want, vertexOf(1, 1)));
}

unittest { // KPS_2: a Point 15 px off an edited quad's corner V adds a vertex at V; the quad is untouched.
    int px, py; Vec3 pressW, mW;
    Vec3[] q;
    setupRig(px, py, pressW, mW, 10.0f, true, q);
    assert(q.length == 4 && faceCountLayer(1) == 1, "setup: the edited quad must be layer 1");
    immutable Vec3 v = q[0];
    cmd("tool.pipe.attr snap enabled true");
    cmd("tool.pipe.attr snap types vertex");
    clickAtPx(px, py);
    assert(vertexCountLayer(1) == 5,
        format("KPS_2: the Point must ADD a vertex (no weld into V); got %d", vertexCountLayer(1)));
    assert(dist(vertexOf(1, 4), v) < 1e-5f,
        format("KPS_2: the new vertex must sit exactly on V %s; got %s", v, vertexOf(1, 4)));
    foreach (i; 0 .. 4)
        assert(dist(vertexOf(1, i), q[i]) < 1e-5f, format("KPS_2: quad vertex %d moved", i));
    assert(hasExactFace(1, [0, 1, 2, 3]), "KPS_2: the quad polygon must be untouched");
}

// 9512 review correction: observe the completed production foreground draw,
// not the election readout or the cell FBO (which excludes ImGui overlays).
private size_t cyanMarkerPixels(Vec3 world) {
    import http_client : quiesce;
    import std.math : round;
    auto vp = viewportFromCamera(fetchCamera());
    float x, y;
    assert(projectToWindow(world, vp, x, y), "marker observation must project the source vertex");
    string points;
    foreach (dy; -1 .. 2) foreach (dx; -1 .. 2) {
        if (points.length) points ~= ";";
        points ~= format("%d,%d", cast(int)round(x) + dx, cast(int)round(y) + dy);
    }
    quiesce(); // provider reads the last COMPLETED ImGui submission
    auto probe = getJson("/api/viewport/probe?target=frame&points=" ~ points);
    assert("error" !in probe && probe["target"].str == "frame"
        && probe["w"].integer > 0 && probe["h"].integer > 0
        && probe["points"].array.length == 9, "marker frame probe must return all nine samples");
    size_t cyan;
    foreach (p; probe["points"].array) {
        assert("error" !in p, "marker frame sample must lie inside the completed framebuffer");
        if (p["r"].integer < 80 && p["g"].integer > 150 && p["b"].integer > 180) ++cyan;
    }
    return cyan;
}

unittest { // actual cyan output survives a constraint-ray miss
    int px, py; Vec3 pressW, mW;
    setupRig(px, py, pressW, mW, 1.0f, false, dummyQ, true);
    cmd("tool.pipe.attr constrain enabled true");
    cmd("tool.pipe.attr constrain handle false");
    cmd("tool.pipe.attr snap types vertex");
    // Below the sole polygon, 9.4 px from its loose T-vertex M: within snap reach.
    // This also separates the elected M from the hover/source-coordinate point.
    cmd("tool.pipe.attr snap enabled false");
    hoverAt(px + 2, py + 12);
    assert(!getJson("/api/tool/state")["hit"].boolean, "Snap OFF control must miss every constraint polygon");
    const offPixels = cyanMarkerPixels(mW);
    assert(offPixels == 0, "Snap OFF must emit no cyan marker at background M");

    cmd("tool.pipe.attr snap enabled true");
    auto hover = hoverAt(px + 2, py + 12);
    assert(!getJson("/api/tool/state")["hit"].boolean, "positive marker witness must remain a constraint-ray miss");
    assert(hover["targetSource"].integer == 1 && hover["targetVert"].integer == 4
        && hover["targetKind"].str == "vertex", "miss election must name actual background M, not hit-face A: " ~ hover.toString);
    const onPixels = cyanMarkerPixels(mW);
    import std.stdio : writeln;
    writeln(format("MISS-MARKER output off=%s on=%s source=1 vertex=4 hit=false world=%s", offPixels, onPixels, mW));
    assert(onPixels >= 5,
        "MISS MARKER ACTUAL OUTPUT: elected background M must reach the completed foreground framebuffer");
    assert(cyanMarkerPixels(hitAt(px + 2, py + 12)) == 0,
        "miss marker must not be drawn at the cursor/source-coordinate point");
}
