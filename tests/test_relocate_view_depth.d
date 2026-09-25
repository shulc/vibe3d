// Action-centre relocate in an orthographic axis view keeps the view-axis
// DEPTH of the centre held before the press (gap 364, task 7134; fixture
// tests/fixtures/relocate_axis_view_depth.json, from the toolcard
// `gizmo_view_cull_plane` addendum).
//
// The measured law: an off-gizmo press with the automatic centre, in a Front
// orthographic view — unpinned, or turned by a pinned plane — lands with the
// view-axis coordinate of the PRE-PRESS centre (plane-local under a pin) and
// takes the other two from the clicked pixel, snapped to 0.01 at pixel
// 0.0078125. The camera focus depth never enters: 0.37, 2.3 and 12.3 are all
// ignored. Before 7134 we wrote the focus depth in the unpinned view (the
// principal-plane chain's locked arm), cast a world ray in the turned view,
// and used the plane origin's depth under a pin.
//
// Why these cells discriminate: every candidate the capture refuted lands at
// a DIFFERENT depth on at least one of them — the focus depth is non-zero in
// all, the plane-origin depth differs from the prior centre in T2-turned, and
// the prior centre is off zero in T3-control. T4-control is not driven: the
// capture itself marks it inadmissible (its centre attribute write did not
// take). Perspective was not captured and is not asserted.
//
// Values are PLANE-LOCAL, `local = B^T (world - origin)`, B = Rx(rotX)·Ry(rotY)
// — our work plane's own Euler order with rotZ = 0 — and the cell's first
// assert checks that this frame reproduces the fixture's own `centre_before`.

import http_client : getJson, postJson;
import drag_helpers : viewportFromCameraMatrices, projectToWindow, DV = Vec3, playAndWait;
import std.file : readText;
import std.format : format;
import std.json;
import std.math : abs, cos, sin, PI, round, tan, lround;
import core.thread : Thread;
import core.time : msecs;

void main() {}

private alias V3 = double[3];
private double num(JSONValue v) {
    return v.type == JSONType.integer ? cast(double) v.integer
         : v.type == JSONType.uinteger ? cast(double) v.uinteger : v.floating;
}
private V3 vec(JSONValue v) { auto a = v.array; return [num(a[0]), num(a[1]), num(a[2])]; }

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok", "/api/command `" ~ line ~ "` failed: " ~ r.toString);
}
void cmdId(string id, string params) {
    auto r = postJson("/api/command", `{"id":"` ~ id ~ `","params":` ~ params ~ `}`);
    assert(r["status"].str == "ok", id ~ " failed: " ~ r.toString);
}
void settle(int ms = 150) { Thread.sleep(ms.msecs); }

/// Row-major B = Rx(a)·Ry(b).
double[3][3] basis(double a, double b) {
    double[3][3] rx = [[1.0, 0, 0], [0.0, cos(a), -sin(a)], [0, sin(a), cos(a)]];
    double[3][3] ry = [[cos(b), 0, sin(b)], [0.0, 1, 0], [-sin(b), 0, cos(b)]];
    double[3][3] m;
    foreach (i; 0 .. 3) foreach (j; 0 .. 3) {
        m[i][j] = 0;
        foreach (k; 0 .. 3) m[i][j] += rx[i][k] * ry[k][j];
    }
    return m;
}
V3 toWorld(double[3][3] B, V3 o, V3 l) {
    V3 w;
    foreach (i; 0 .. 3) w[i] = o[i] + B[i][0] * l[0] + B[i][1] * l[1] + B[i][2] * l[2];
    return w;
}
V3 toLocal(double[3][3] B, V3 o, V3 w) {
    V3 l;
    foreach (j; 0 .. 3) l[j] = B[0][j] * (w[0] - o[0]) + B[1][j] * (w[1] - o[1]) + B[2][j] * (w[2] - o[2]);
    return l;
}

/// The published action centre (world) and whether a relocate placed it.
V3 centre(out bool placed) {
    auto a = getJson("/api/toolpipe/eval")["actionCenter"];
    placed = a["isUserPlaced"].type == JSONType.true_;
    return vec(a["center"]);
}

void click(int x, int y) {
    auto c = getJson("/api/camera");
    playAndWait(format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~
        `{"t":30.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n" ~
        `{"t":60.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n" ~
        `{"t":90.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        c["vpX"].integer, c["vpY"].integer, c["width"].integer, c["height"].integer,
        x, y, x, y, x, y));
    settle();
}

/// World length of one pixel of the active (ortho) cell.
double pixelSize() {
    auto c = getJson("/api/camera");
    return 2.0 / (num(c["projMatrix"].array[5]) * cast(double) c["height"].integer);
}

void runCell(string name, JSONValue fx, ref int judged) {
    auto c = fx["cells"][name];
    auto pp = c["pinned_plane"].array;
    immutable V3 o = [num(pp[0]), num(pp[1]), num(pp[2])];
    immutable double rx = num(pp[3]), ry = num(pp[4]);
    immutable bool pinned = abs(rx) + abs(ry) + abs(o[0]) + abs(o[1]) + abs(o[2]) > 0;
    immutable B = basis(rx, ry);
    immutable V3 before = vec(c["centre_before"]);

    // The cube (edge 0.5) sits at the pre-press centre, and is SELECTED only
    // where the capture's centre was a selection's (T3: the box centre of the
    // selected cube); otherwise the automatic centre is the whole mesh's.
    immutable V3 at = toWorld(B, o, before);
    string verts = "[";
    foreach (i; 0 .. 8) {
        if (i) verts ~= ",";
        verts ~= format("[%.9f,%.9f,%.9f]", at[0] + ((i & 1) ? 0.25 : -0.25),
            at[1] + ((i & 2) ? 0.25 : -0.25), at[2] + ((i & 4) ? 0.25 : -0.25));
    }
    verts ~= "]";
    cmdId("scene.reset", `{"empty":true}`);
    cmd("workplane.reset");
    cmdId("scene.loadMesh", `{"vertices":` ~ verts ~ `,"faces":[[0,2,3,1],[4,5,7,6],[0,1,5,4],[2,6,7,3],[0,4,6,2],[1,3,7,5]]}`);
    if (name == "T3-control")
        cmdId("mesh.select", `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`);
    cmd("viewport.view Front");
    if (pinned)
        cmd(format("workplane.edit cenX:%.9f cenY:%.9f cenZ:%.9f rotX:%.9f rotY:%.9f rotZ:0",
            o[0], o[1], o[2], rx * 180 / PI, ry * 180 / PI));
    cmd("tool.set move on");
    cmd("actr.auto");
    immutable V3 focus = toWorld(B, o, vec(c["focus_local"]));
    auto r = postJson("/api/camera", format(`{"focus":{"x":%.9f,"y":%.9f,"z":%.9f}}`, focus[0], focus[1], focus[2]));
    assert(r["status"].str == "ok", "camera failed: " ~ r.toString);
    // Zoom so one pixel is the capture's 0.0078125 (the snap step is a
    // function of it): pixel size is linear in the ortho distance.
    immutable double want = num(fx["pixel_size"]);
    foreach (_; 0 .. 3) {
        immutable double d = num(getJson("/api/camera")["distance"]);
        postJson("/api/camera", format(`{"distance":%.9f}`, d * want / pixelSize()));
    }
    settle(250);

    // Premises: ortho, looking along the plane's local -Z, the right pixel,
    // and our pre-press centre IS the capture's.
    auto cam = getJson("/api/camera");
    assert(cam["projKind"].str == "Ortho", name ~ " premise: Front must be orthographic");
    immutable V3 fwdLocal = toLocal(B, [0.0, 0.0, 0.0], [-num(cam["viewMatrix"].array[2]),
        -num(cam["viewMatrix"].array[6]), -num(cam["viewMatrix"].array[10])]);
    assert(abs(fwdLocal[2] + 1) < 1e-4, format("%s premise: the view does not look along local -Z: %s", name, fwdLocal));
    assert(abs(pixelSize() - want) < 1e-7, format("%s premise: pixel size %.9g, capture %.9g", name, pixelSize(), want));
    bool placed;
    immutable V3 c0 = toLocal(B, o, centre(placed));
    foreach (k; 0 .. 3)
        assert(abs(c0[k] - before[k]) < 1e-4,
            format("%s premise: pre-press centre %s (local), capture %s", name, c0, before));

    // The cell centre is where the focus projects.
    auto vp = viewportFromCameraMatrices();
    float fx0, fy0;
    projectToWindow(DV(cast(float) focus[0], cast(float) focus[1], cast(float) focus[2]), vp, fx0, fy0);
    immutable double step = num(fx["snap_step"]);
    foreach (i, off; fx["click_offsets_px"].array) {
        click(cast(int) lround(fx0 + num(off[0])), cast(int) lround(fy0 + num(off[1])));
        immutable V3 got = toLocal(B, o, centre(placed));
        immutable V3 exp = vec(c["centre_after_clicks"].array[i]);
        assert(placed, format("%s click %d: the off-gizmo press did not relocate the centre", name, i + 1));
        assert(abs(got[2] - exp[2]) <= 1e-4,
            format("relocate did not keep the pre-press centre's view depth (%s, click %d): local z %.6f, "
                ~ "capture %.6f (focus depth %.6f)", name, i + 1, got[2], exp[2], num(c["focus_local"][2])));
        foreach (k; 0 .. 2) {
            assert(abs(got[k] - exp[k]) <= step + 1e-5,
                format("%s click %d: landing %s (local) is not at the clicked pixel, capture %s", name, i + 1, got, exp));
            assert(abs(got[k] / step - round(got[k] / step)) * step <= 2e-5,
                format("relocate landing is not snapped to the view sub-step (%s, click %d): local %s, step %g",
                    name, i + 1, got, step));
        }
        ++judged;
    }
    cmd("tool.set move off");
    cmd("workplane.reset");
}

unittest {
    auto fx = parseJSON(readText("tests/fixtures/relocate_axis_view_depth.json"));
    int judged;
    foreach (name; ["R-control", "T2-control", "T3-control", "R-turned", "T2-turned"])
        runCell(name, fx, judged);
    assert(judged == 10, format("judged %d landings, expected 10", judged));
}
