// test_tool_overlay_line_pixels.d — the tool overlay lines (Move's Ctrl-lock
// constraint line, Radial Sweep's axis, Mirror's plane quad + dashed normal)
// are GL draws into the cell FBO, so `/api/viewport/probe` reads them. Each
// cell probes 7 pixels ACROSS the projected line at one world point and pins
// the measured line pixels (anti-aliased coverage: width, a missing segment
// or a solid dash all change them) and the background 3 px off the line.
// Mirror at default params has normal -X, so the quad's CLOSING edge c3 -> c0
// lies at z = -qs (qs = 0.9 arm) and the dashes (0.10qs, gap 0.07qs) run
// t = -1.3qs .. +1.3qs at world x = -t. Task 9442 step 0: green and able to
// redden on the tree before the drawers moved. One cell: VIBE3D_CELL=<name>.

import http_client : getJson, postJson, postRaw;
import http_command_helpers : commandBody;
import std.format : format;
import std.json;
import std.math : abs, lround, sqrt;
import std.process : environment;

import drag_helpers;

void main() {}

private enum int SLOP = 3;
private enum uint MOD_CTRL = 0x00C0;
private alias Rgb = int[3];
private enum Rgb kSky = [92, 102, 107];

private bool cellOn(string name) {
    auto want = environment.get("VIBE3D_CELL", "");
    return want.length == 0 || want == name;
}

private void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok", "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

private void resetScene(string camera) {
    cmd(commandBody("scene.reset"));
    cmd("history.clear");
    postRaw("/api/camera", camera);
}

private enum string kCamDefault = `{"azimuth":0.5,"elevation":0.4,"distance":3.0}`;
// Low and far, so the mirror overlay at y = 1.2 sits on plain background
// above the horizon, clear of the grid.
private enum string kCamMirror  = `{"azimuth":0.5,"elevation":0.05,"distance":6.0}`;

// The 7 pixels k = -3 .. +3 across the projected line a->b at world point p.
private Rgb[] stripAcross(Vec3 a, Vec3 b, Vec3 p) {
    auto cam = fetchCamera();
    auto vp = viewportFromCamera(cam);
    float ax, ay, bx, by, px, py;
    assert(projectToWindow(a, vp, ax, ay) && projectToWindow(b, vp, bx, by)
           && projectToWindow(p, vp, px, py), "a strip point projects off-camera");
    float dx = bx - ax, dy = by - ay, l = sqrt(dx * dx + dy * dy);
    float nx = -dy / l, ny = dx / l;
    string q = "/api/viewport/probe?points=";
    foreach (k; -3 .. 4) {
        if (k > -3) q ~= ";";
        q ~= format("%d,%d", lround(px + nx * k) - cam.vpX, lround(py + ny * k) - cam.vpY);
    }
    auto j = getJson(q);
    assert("error" !in j, "probe failed: " ~ j.toString);
    assert(j["renders"].type == JSONType.TRUE,
           "the probed cell is not rendered under --test; the reading is void");
    Rgb[] o;
    foreach (e; j["points"].array) {
        assert("error" !in e, "probe point failed: " ~ e.toString);
        o ~= [cast(int)e["r"].integer, cast(int)e["g"].integer, cast(int)e["b"].integer];
    }
    assert(o.length == 7, format("probe answered %d of 7 points", o.length));
    return o;
}

private bool near(Rgb got, Rgb want) {
    return abs(got[0] - want[0]) <= SLOP && abs(got[1] - want[1]) <= SLOP
        && abs(got[2] - want[2]) <= SLOP;
}

// `line[i]` is the pinned colour of strip pixel k = lineK[i]; k = -3 and +3
// are the background.
private void expectStrip(string cell, Rgb[] s, const int[] lineK, const Rgb[] line, Rgb bg) {
    assert(near(s[0], bg) && near(s[6], bg),
           format("%s: the pixels 3 px off the line must be background %s; strip %s",
                  cell, bg, s));
    foreach (i, k; lineK)
        assert(near(s[k + 3], line[i]),
               format("%s: line pixel k=%d must read %s; strip %s", cell, k, line[i], s));
}

// ---------------------------------------------------------------------------
// Radial Sweep — the solid axis line S -> E (defaults: axis +Y, centre 0)
// ---------------------------------------------------------------------------

unittest {
    if (!cellOn("sweep-axis")) return;
    resetScene(kCamDefault);
    cmd("tool.set mesh.radialSweepTool on");
    scope(exit) cmd("tool.set mesh.radialSweepTool off");
    auto s = stripAcross(Vec3(0, -1, 0), Vec3(0, 1, 0), Vec3(0, 0.6f, 0));
    expectStrip("sweep-axis", s, [-1, 0], [[149, 123, 60], [149, 123, 60]], [81, 81, 81]);
}

// ---------------------------------------------------------------------------
// Move — the Ctrl-lock constraint line (locked to Y by a screen-down drag)
// ---------------------------------------------------------------------------

unittest {
    if (!cellOn("move-constraint")) return;
    resetScene(kCamDefault);
    cmd(commandBody("mesh.select", `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`));
    cmd("tool.set move on");
    auto cam = fetchCamera();
    auto vp = viewportFromCamera(cam);
    float cx, cy;
    assert(projectToWindow(Vec3(0, 0, 0), vp, cx, cy));
    immutable int x0 = cast(int)cx, y0 = cast(int)cy;
    playAndWait(buildDragDownLog(cam.vpX, cam.vpY, cam.width, cam.height, x0, y0, MOD_CTRL));
    playAndWait(buildDragMotionLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                   x0, y0, x0, y0 + 40, 10, MOD_CTRL));
    scope(exit) {
        playAndWait(buildDragUpLog(cam.vpX, cam.vpY, cam.width, cam.height, x0, y0 + 40, MOD_CTRL));
        cmd("tool.set move off");
    }
    auto locked = getJson("/api/toolpipe/eval")["transform"]["constraintLockedAxis"].integer;
    assert(locked == 1, format("premise: the drag must lock world Y, locked %d", locked));
    // The line runs through the (moved) pivot, +-3 arms along Y; sample two
    // arms up — past the Y arrow's tip, inside the line's reach.
    double sumY = 0;
    foreach (i; 0 .. 8) sumY += vertexPos(i)[1];
    Vec3 ctr = Vec3(0, cast(float)(sumY / 8), 0);
    float arm = gizmoSize(ctr, vp);
    auto s = stripAcross(ctr, ctr + Vec3(0, arm, 0), ctr + Vec3(0, 2 * arm, 0));
    expectStrip("move-constraint", s, [-1, 0], [[144, 142, 105], [144, 142, 105]], kSky);
}

// ---------------------------------------------------------------------------
// Mirror — the plane's wire quad (closing edge) and its dashed normal
// ---------------------------------------------------------------------------

private enum float kMirrorCy = 1.2f;

// Arms the tool with its centre at (0, kMirrorCy, 0); returns qs.
private float armMirror() {
    resetScene(kCamMirror);
    cmd("tool.set mesh.mirrorTool on");
    cmd(`{"id":"tool.attr","params":{"_positional":["mesh.mirrorTool","center",[0,1.2,0]]}}`);
    auto vp = viewportFromCamera(fetchCamera());
    return 0.9f * gizmoSize(Vec3(0, kMirrorCy, 0), vp);
}

unittest {
    if (!cellOn("mirror-close")) return;
    immutable float qs = armMirror();
    scope(exit) cmd("tool.set mesh.mirrorTool off");
    auto s = stripAcross(Vec3(0, kMirrorCy + qs, -qs), Vec3(0, kMirrorCy - qs, -qs),
                         Vec3(0, kMirrorCy, -qs));
    expectStrip("mirror-close", s, [0, 1], [[178, 76, 182], [97, 100, 112]], kSky);
}

unittest {
    if (!cellOn("mirror-dash")) return;
    immutable float qs = armMirror();
    scope(exit) cmd("tool.set mesh.mirrorTool off");
    // Dash 7 of the loop t = -1.3qs step 0.17qs ends nearest the centre, so a
    // small error in the arm barely moves it or the gap after it.
    float t = -qs * 1.3f;
    foreach (_; 0 .. 7) t += qs * 0.10f + qs * 0.07f;
    immutable float dashMid = t + qs * 0.05f, gapMid = t + qs * 0.135f;
    Vec3 a = Vec3(-1, kMirrorCy, 0), b = Vec3(1, kMirrorCy, 0);
    auto dash = stripAcross(a, b, Vec3(-dashMid, kMirrorCy, 0));
    expectStrip("mirror-dash", dash, [-1, 0], [[138, 88, 147], [126, 92, 137]], kSky);
    auto gap = stripAcross(a, b, Vec3(-gapMid, kMirrorCy, 0));
    foreach (k, px; gap)
        assert(near(px, kSky),
               format("mirror-dash: the gap after dash 7 must be bare background at k=%d; strip %s",
                      cast(int)k - 3, gap));
}
