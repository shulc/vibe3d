// The topology pen's Move law and the constraint's Screen re-cast (task 9510,
// captures K-SC and K-DW; the numbers below are their cells).
//   * Every Move is a RIGID drag of the grab point through the shared
//     translator's free form (K-DW: with no background a vertex above the
//     work plane keeps its height), re-cast along the view onto the
//     background under it whatever the geometry setting (K-SC mv_g0); the
//     constraint's geometry pass then runs on EACH moved vertex (mv_scr,
//     mv_pt, mvd_*).
//   * Screen takes the NEAREST hit on the view line through the offset point,
//     either direction (ovh_hi, ovh_lo, ovh_flank); the offset never goes
//     below 0 (scr_neg).
//   * The polygon pen runs no geometry pass (ppen_scr == ppen_g0).
// Rig (K-SC): sphere 64x32, r 1, centre (0,1,0) on a background layer; top
// ortho, focus (0.07,1,0), 439.52 px/m (q 0.005). Heights carry the capture's
// depth/facet bias (1-3e-3), so a height is held to 5e-3 and every cell names
// the rival candidate it must stay clear of. VIBE3D_CELL=<name>[,<name>...]
// runs only those blocks (mutation drills).

import drag_helpers : Vec3, Viewport, buildDragLog, fetchCamera, pixelRay, playAndWait,
    projectToWindow, viewportFromCameraMatrices;
import pen_rig_helpers : clickPixels, penCameraAt, penCommand, penSceneEmpty, readVerts,
    worldPixel;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.format : format;
import std.algorithm : canFind;
import std.array : split;
import std.math : PI, abs, sqrt;
import std.process : environment;

void main() {}

private enum double kPpm = 439.52;

private bool runs(string cell) {
    const f = environment.get("VIBE3D_CELL", "");
    return f.length == 0 || f.split(",").canFind(cell);
}
private immutable Vec3 kCentre = Vec3(0, 1, 0);

private void loadMesh(string json) {
    auto r = postJson("/api/command", commandBody("scene.loadMesh", json));
    assert(r["status"].str == "ok", "rig: mesh load failed: " ~ r.toString);
}

/// Background sphere in layer 0, optionally an overhang quad in a second
/// background layer, an Edit layer on top (optionally the capture's quad), the
/// top camera, the topology pen in `mode`, then the constraint as captured
/// (handle off, double-sided as the capture's preset read back).
private void rig(string mode, string geometry, double offset, string overhang = null,
                 bool quad = false) {
    penSceneEmpty("Top");
    penCommand("prim.sphere cenX:0 cenY:1 cenZ:0 sizeX:1 sizeY:1 sizeZ:1 sides:64 segments:32");
    if (overhang.length) {
        penCommand("layer.add name:Over");
        loadMesh(overhang);
    }
    penCommand("layer.add name:Edit");
    if (quad)
        loadMesh(`{"vertices":[[0.1,1.994987,0],[0.1,1.860233,0.5],[-0.1,1.860233,0.5],`
                 ~ `[-0.1,1.994987,0]],"faces":[[0,1,2,3]]}`);
    penCommand("viewport.view Top");   // a load leaves the view perspective
    penCameraAt(Vec3(0.07f, 1, 0), kPpm);
    assert(getJson("/api/camera")["projKind"].str == "Ortho", "rig premise: the top view is orthographic");
    penCommand("tool.set mesh.topoPen on");
    penCommand("tool.attr mesh.topoPen mode " ~ mode);
    penCommand("tool.pipe.attr constrain enabled true");
    penCommand("tool.pipe.attr constrain handle false");
    penCommand("tool.pipe.attr constrain dblSided true");
    penCommand("tool.pipe.attr constrain geometry " ~ geometry);
    penCommand(format("tool.pipe.attr constrain offset %.9f", offset));
    penCommand(`tool.pipe.attr snap types ""`);   // snapping off, as captured
}

/// An overhang quad at height `y` over x 0.315..0.7, z 0..0.45 (or the flank's).
private string overhangAt(double y, double x0 = 0.315, double x1 = 0.7, double z0 = 0,
                          double z1 = 0.45) {
    return format(`{"vertices":[[%s,%s,%s],[%s,%s,%s],[%s,%s,%s],[%s,%s,%s]],"faces":[[0,1,2,3]]}`,
                  x1, y, z0, x1, y, z1, x0, y, z1, x0, y, z0);
}

private double dxz(Vec3 a, double[3] b) {
    return sqrt((a.x - b[0]) ^^ 2 + (a.z - b[2]) ^^ 2);
}

private string fmt(Vec3 v) { return format("(%.6f, %.6f, %.6f)", v.x, v.y, v.z); }

/// One click at the plane point (x, 1, z); the one placed vertex.
private Vec3 clickAt(string cell, double x, double z) {
    clickPixels(worldPixel(Vec3(cast(float)x, 1, cast(float)z)));
    auto vs = readVerts();
    assert(vs.length == 1, format("%s: one click places one vertex; got %s", cell, vs.length));
    return vs[0];
}

private void near(string cell, Vec3 p, double[3] want, double xzTol, double yTol, string rival) {
    assert(dxz(p, want) <= xzTol && abs(p.y - want[1]) <= yTol,
           format("%s: placed %s, captured (%(%.6f, %)) — xz %.6f (tol %g), y %.6f (tol %g); "
                  ~ "the rival: %s", cell, fmt(p), want[], dxz(p, want), xzTol,
                  abs(p.y - want[1]), yTol, rival));
}

// ---------------------------------------------------------------------------
// Screen: the nearest hit on the view line. ovh_hi first (the control both
// rules agree on), then the two cells a forward-only cast reads wrong.
// ---------------------------------------------------------------------------

unittest { // ovh_hi — overhang 0.18 above the offset point: the sphere below is nearer
    if (!runs("ovh_hi")) return;
    rig("point", "screen", 0.1, overhangAt(2.2));
    near("ovh_hi", clickAt("ovh_hi", 0.3020675, 0.19794), [0.364253, 2.007031, 0.241801],
         0.01, 5e-3, "the first hit from the eye, the overhang (0.329, 2.1, 0.217)");
}

unittest { // ovh_lo — overhang 0.056 above: nearer than the sphere, so taken (y 2.08 - 0.1)
    if (!runs("ovh_lo")) return;
    rig("point", "screen", 0.1, overhangAt(2.08));
    near("ovh_lo", clickAt("ovh_lo", 0.3020675, 0.19794), [0.331175, 1.98, 0.220282],
         0.01, 1e-3, "a forward-only cast, the sphere (0.364, 2.007, 0.242)");
}

unittest { // ovh_flank — overhang 0.213 above, sphere 0.233 below: the overhang
    if (!runs("ovh_flank")) return;
    rig("point", "screen", 0.1, overhangAt(1.78, 0.84, 1.2, 0.15, 0.5));
    near("ovh_flank", clickAt("ovh_flank", 0.8, 0.3), [0.879842, 1.68, 0.329678],
         0.01, 1e-3, "a forward-only cast, the sphere (0.97, 1.38, 0.36)");
}

unittest { // scr_neg — offset -0.1 reads back 0 and places the offset-0 point
    if (!runs("scr_neg")) return;
    rig("point", "screen", -0.1);
    string got;
    foreach (st; getJson("/api/toolpipe")["stages"].array)
        if (st["task"].str == "CONS") got = st["attrs"]["offset"].str;
    import std.conv : to;
    assert(got.length && got.to!double == 0,
           format("scr_neg: the offset -0.1 must read back 0; got '%s'", got));
    near("scr_neg", clickAt("scr_neg", 0.3020675, 0.19794), [0.3, 1.930522, 0.2],
         5e-3, 5e-3, "the unclamped offset, 0.1 inside the sphere (0.29, 1.83, 0.19)");
}

// ---------------------------------------------------------------------------
// Move: rigid grab drag, then the per-vertex geometry pass. Press on the
// midpoint pixel of edge v0-v1, drag (dx, dy) px; v2 / v3 must not move.
// ---------------------------------------------------------------------------

private Vec3[2] moveCell(string cell, string geometry, int dx, int dy) {
    rig("move", geometry, 0, null, true);
    auto before = readVerts();
    assert(before.length == 4, format("%s: rig quad has 4 vertices; got %s", cell, before.length));
    const p = worldPixel((before[0] + before[1]) * 0.5f);
    const cam = fetchCamera();
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height, p[0], p[1],
                             p[0] + dx, p[1] + dy, 16, 0, 1));
    auto after = readVerts();
    assert(after.length == 4, format("%s: the move keeps 4 vertices; got %s", cell, after.length));
    foreach (i; 2 .. 4)
        assert(after[i] == before[i], format("%s: vertex %s moved (%s -> %s)", cell, i, before[i], after[i]));
    return [after[0], after[1]];
}

private double sphereDist(Vec3 p) {
    const d = p - kCentre;
    return sqrt(cast(double)(d.x * d.x + d.y * d.y + d.z * d.z)) - 1.0;
}

private void moveWitness(string cell, string geometry, int dx, int dy, double[3] v0, double[3] v1,
                         string rival) {
    const v = moveCell(cell, geometry, dx, dy);
    near(cell ~ " v0", v[0], v0, 3e-3, 5e-3, rival);
    near(cell ~ " v1", v[1], v1, 3e-3, 5e-3, rival);
}

unittest { // mvd_pt / mv_pt — geometry Point: each vertex at its nearest foot (the control)
    if (!runs("mv_pt")) return;
    moveWitness("mv_pt", "point", 160, 0, [0.452167, 1.889439, -0.000111],
                [0.44752, 1.750385, 0.480914], "the rigid move alone (mv_g0)");
    moveWitness("mvd_pt", "point", 120, 90, [0.385234, 1.896027, 0.210364],
                [0.344742, 1.676465, 0.646413], "the rigid move alone (mvd_g0)");
}

unittest { // mv_g0 — geometry off: rigid, only the grab point lands on the sphere
    if (!runs("mv_g0")) return;
    moveWitness("mv_g0", "off", 160, 0, [0.465, 1.914129, -0.000269], [0.465, 1.779375, 0.499731],
                "each vertex on its nearest foot, v0 (0.453, 1.889, 0)");
    const v = moveCell("mv_g0", "off", 160, 0);
    assert(sphereDist(v[0]) > 0.015 && sphereDist(v[1]) > 0.025,
           format("mv_g0: the vertices stay off the sphere (captured 0.026 / 0.036); got %.4f / %.4f",
                  sphereDist(v[0]), sphereDist(v[1])));
    moveWitness("mvd_g0", "off", 120, 90, [0.375, 1.872137, 0.204731], [0.375, 1.737383, 0.704731],
                "each vertex on its nearest foot");
}

unittest { // mv_scr — geometry Screen: each vertex re-cast along the view (xz kept)
    if (!runs("mv_scr")) return;
    moveWitness("mv_scr", "screen", 160, 0, [0.465, 1.882768, -0.000269],
                [0.465, 1.727026, 0.499731], "the nearest foot, v0 x 0.453 (mv_pt)");
    moveWitness("mvd_scr", "screen", 120, 90, [0.375, 1.901739, 0.204731],
                [0.375, 1.597257, 0.704731], "the rigid move alone (mvd_g0)");
}

// ---------------------------------------------------------------------------
// Move with no background (K-DW): the shared translator's free form.
// ---------------------------------------------------------------------------

/// The pen in move mode, snapping off; drag the loaded quad's corner V by
/// (dx, dy) px; V's end position.
private Vec3 dragVertex(string cell, Vec3 v, int dx, int dy) {
    penCommand("tool.set mesh.topoPen on");
    penCommand("tool.attr mesh.topoPen mode move");
    penCommand(`tool.pipe.attr snap types ""`);
    const p = worldPixel(v);
    const cam = fetchCamera();
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height, p[0], p[1],
                             p[0] + dx, p[1] + dy, 16, 0, 1));
    auto vs = readVerts();
    assert(vs.length == 4, format("%s: the move keeps 4 vertices; got %s", cell, vs.length));
    return vs[0];
}

unittest { // DW_Pc — front ortho, 0.01 m/px, V 0.5 m in front of the work plane: all agree
    if (!runs("DW_Pc")) return;
    penSceneEmpty("Front");
    loadMesh(`{"vertices":[[0.2,0.2,0.5],[0.6,0.2,0.5],[0.6,0.6,0.5],[0.2,0.6,0.5]],"faces":[[0,1,2,3]]}`);
    penCommand("viewport.view Front");   // a load leaves the view perspective
    penCameraAt(Vec3(0, 0, 0), 100);
    assert(getJson("/api/camera")["projKind"].str == "Ortho", "rig premise: the front view is orthographic");
    const v = dragVertex("DW_Pc", Vec3(0.2f, 0.2f, 0.5f), -35, -35);
    assert(abs(v.x + 0.15) <= 1e-5 && abs(v.y - 0.55) <= 1e-5 && abs(v.z - 0.5) <= 1e-6,
           format("DW_Pc: V ends %s, captured (-0.15, 0.55, 0.5)", fmt(v)));
}

unittest { // DW_P — perspective, no background, V 0.5 m above the work plane
    if (!runs("DW_P")) return;
    // The capture's camera (60 degrees down, f 1005 px) is not ours, so the
    // cell pins the law's terms rather than its numbers: V keeps its height
    // (the view plane through V moves it 0.107 m off the plane), and V lands
    // under the cursor (the work-plane delta lands it 0.03-0.04 m away there:
    // the premise below measures that rival on OUR camera).
    penSceneEmpty("Top");
    loadMesh(`{"vertices":[[-1.2,0.5,-0.4],[-1.2,0.5,0.2],[-0.6,0.5,0.2],[-0.6,0.5,-0.4]],"faces":[[0,1,2,3]]}`);
    assert(getJson("/api/camera")["projKind"].str == "Perspective", "rig premise: a perspective view");
    penCameraAt(Vec3(0, 0, 0), 250, 0, PI / 3);
    const Vec3 v0 = Vec3(-1.2f, 0.5f, -0.4f);
    const int dx = -35, dy = -35;
    const v = dragVertex("DW_P", v0, dx, dy);
    Viewport vp = viewportFromCameraMatrices();
    float sx0, sy0, sx, sy;
    assert(projectToWindow(v0, vp, sx0, sy0) && projectToWindow(v, vp, sx, sy), "DW_P: V must project");
    const int[2] press = worldPixel(v0);
    const double ex = press[0] + dx + (sx0 - press[0]), ey = press[1] + dy + (sy0 - press[1]);
    const double miss = sqrt((sx - ex) ^^ 2 + (sy - ey) ^^ 2);
    // The rival: the same travel measured on the work plane (y 0) and carried to V.
    Vec3 o, d;
    pixelRay(press[0] + 0.5f, press[1] + 0.5f, vp, o, d);
    const Vec3 h0 = o + d * (-o.y / d.y);
    pixelRay(press[0] + dx + 0.5f, press[1] + dy + 0.5f, vp, o, d);
    const Vec3 h1 = o + d * (-o.y / d.y);
    float rx, ry;
    assert(projectToWindow(v0 + (h1 - h0), vp, rx, ry), "DW_P: the rival must project");
    const double rivalMiss = sqrt((rx - ex) ^^ 2 + (ry - ey) ^^ 2);
    assert(rivalMiss >= 4, format("DW_P premise: the work-plane delta must land >= 4 px off; %.2f px", rivalMiss));
    assert(abs(v.y - 0.5) <= 1e-5 && miss <= 2,
           format("DW_P: V ends %s, %.2f px from the cursor (tol 2; the work-plane delta %.2f px), "
                  ~ "height %.6f (must stay 0.5)", fmt(v), miss, rivalMiss, v.y));
}

// ---------------------------------------------------------------------------
// The polygon pen runs no geometry pass: Screen places exactly what geometry
// off does, the single offset (ppen_scr == ppen_g0).
// ---------------------------------------------------------------------------

private Vec3[] polygonPen(string geometry) {
    penSceneEmpty("Top");
    penCommand("layer.add name:Bg");
    penCommand("prim.sphere cenX:0 cenY:1 cenZ:0 sizeX:1 sizeY:1 sizeZ:1 sides:64 segments:32");
    penCommand("layer.setVisible index:1 value:true");
    penCommand("layer.select index:0");
    penCommand("tool.pipe.attr snap enabled false");
    penCameraAt(Vec3(0.07f, 1, 0), kPpm);
    penCommand("tool.pipe.attr constrain enabled true");
    penCommand("tool.pipe.attr constrain geometry " ~ geometry);
    penCommand("tool.pipe.attr constrain offset 0.1");
    penCommand("tool.pipe.attr constrain handle true");
    penCommand("tool.set pen on");
    int[2][] px;
    foreach (q; [[0.3, 0.2], [-0.4, -0.3], [0.1, -0.6], [0.8, 0.0]])
        px ~= worldPixel(Vec3(cast(float)q[0], 1, cast(float)q[1]));
    clickPixels(px);
    penCommand("tool.set pen off");
    return readVerts();
}

unittest { // ppen_g0 (the control) then ppen_scr: bit for bit, and the captured points
    if (!runs("ppen")) return;
    const off = polygonPen("off");
    const scr = polygonPen("screen");
    immutable double[3][] want = [[0.331175, 2.023491, 0.220282], [-0.44013, 1.949637, -0.330533],
                                  [0.10963, 1.869568, -0.659853], [0.879633, 1.655205, -0.000977]];
    assert(off.length == 4, format("ppen_g0: 4 points; got %s", off));
    foreach (i, w; want)
        near(format("ppen_g0 point %s", i), off[i], w, 5e-3, 5e-3, "the double offset, 0.16 off");
    assert(scr == off, format("ppen_scr: Screen must place what geometry off does; %s vs %s", scr, off));
}
