// The topology pen's Ctrl+LMB drag with no background (task 9528, capture
// K-FH, cells KFH_TS_V / _E / _VSK / _ESK): the pressed vertex or edge moves
// along ONE world axis, elected at the first motion past the click gate from
// the quantised drag offset, a tie going to the higher axis; the offset is the
// shared translator's free form `q(H+T) - q(H)` on that axis, H the vertex or
// the edge point under the press. Rig as captured: one quad at y 0, top ortho,
// 0.002275172049 m/px (q 0.005), snap off, the drag path of each round.
// VIBE3D_CELL=<name>[,<name>...] runs only those blocks (mutation drills).

import drag_helpers : Vec3, Viewport, dot, fetchCamera, kPaceLine, playAndWait, projectToWindow,
    viewportFromCameraMatrices;
import pen_rig_helpers : penCameraAt, penCommand, penSceneEmpty, readVerts;
import http_client : postJson;
import http_command_helpers : commandBody;
import std.algorithm : canFind;
import std.array : split;
import std.format : format;
import std.math : abs, round;
import std.process : environment;

void main() {}

private enum double kPpm = 1.0 / 0.002275172049;
private enum int LCTRL = 64;

private bool runs(string cell) {
    const f = environment.get("VIBE3D_CELL", "");
    return f.length == 0 || f.split(",").canFind(cell);
}

// The square quad of KFH_TS_V/E and the skewed one of KFH_TS_VSK/ESK.
private immutable double[3][4] kSquare = [[0.2977, 0, 0.1979], [0.4977, 0, 0.1979],
                                          [0.4977, 0, 0.3979], [0.2977, 0, 0.3979]];
private immutable double[3][4] kSkew = [[0.2977, 0, 0.1979], [0.4977, 0, 0.2979],
                                        [0.4477, 0, 0.4979], [0.2477, 0, 0.3979]];
// Round 1 drags 14 x (5,-3) px; round 2 starts (6,-1), (4,-5), then 12 x (5,-3).
private int[2][] round1() { int[2][] p; foreach (i; 0 .. 14) p ~= [5, -3]; return p; }
private int[2][] round2() { int[2][] p = [[6, -1], [4, -5]]; foreach (i; 0 .. 12) p ~= [5, -3]; return p; }

/// The quad, the top camera centred on the grab point `h` (so the press pixel
/// is exactly `h`), the pen in Move mode, snapping off; the press pixel.
private int[2] rig(const double[3][4] quad, Vec3 h, bool transformed = false) {
    penSceneEmpty("Top");
    string vs;
    foreach (i, v; quad) vs ~= format("%s[%.9f,%.9f,%.9f]", i ? "," : "", v[0], v[1], v[2]);
    auto r = postJson("/api/command", commandBody("scene.loadMesh",
        `{"vertices":[` ~ vs ~ `],"faces":[[0,1,2,3]]}`));
    assert(r["status"].str == "ok", "rig: mesh load failed: " ~ r.toString);
    if (transformed) {
        penCommand("layer.attr 0 pos.x 0.3");
        penCommand("layer.attr 0 pos.z 0.2");
        penCommand("layer.attr 0 rot.y 90");
        penCommand("layer.attr 0 scl.x 2");
        penCommand("layer.attr 0 scl.y 3");
        penCommand("layer.attr 0 scl.z 0.5");
    }
    penCommand("viewport.view Top");
    penCameraAt(h, kPpm);
    penCommand("tool.set mesh.topoPen on");
    penCommand("tool.attr mesh.topoPen mode move");
    penCommand(`tool.pipe.attr snap types ""`);
    Viewport vp = viewportFromCameraMatrices();
    float px, py;
    assert(projectToWindow(h, vp, px, py), "rig: the grab point must project");
    int[2] p = [cast(int)round(px), cast(int)round(py)];
    assert(abs(px - p[0]) < 1e-3 && abs(py - p[1]) < 1e-3,
           format("rig premise: the grab point sits on a pixel; got (%s, %s)", px, py));
    return p;
}

/// Ctrl+LMB at `at`, one motion per step of `path`, the release at the end.
private void ctrlDrag(int[2] at, const int[2][] path) {
    auto cam = fetchCamera();
    string log = format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,`
        ~ `"fovY":0.785398}` ~ "\n" ~ kPaceLine, cam.vpX, cam.vpY, cam.width, cam.height);
    string ev(double t, string type, int x, int y, string tail) {
        return format(`{"t":%.1f,"type":"%s","x":%d,"y":%d,%s,"mod":%d}` ~ "\n", t, type, x, y, tail, LCTRL);
    }
    log ~= ev(20, "SDL_MOUSEMOTION", at[0], at[1], `"xrel":0,"yrel":0,"state":0`);
    log ~= ev(40, "SDL_MOUSEBUTTONDOWN", at[0], at[1], `"btn":1,"clicks":1`);
    int x = at[0], y = at[1];
    double t = 40;
    foreach (s; path) {
        x += s[0]; y += s[1]; t += 20;
        log ~= ev(t, "SDL_MOUSEMOTION", x, y, `"xrel":0,"yrel":0,"state":1`);
    }
    log ~= ev(t + 20, "SDL_MOUSEBUTTONUP", x, y, `"btn":1,"clicks":1`);
    playAndWait(log);
}

/// Every vertex where the cell's mesh_after has it (1e-4: the rivals sit
/// >= 2e-3 away), naming the rival law the cell separates.
private void expect(string cell, const double[3][4] want, string rival) {
    auto vs = readVerts();
    assert(vs.length == 4, format("%s: the quad keeps 4 vertices; got %s", cell, vs.length));
    foreach (i, v; vs)
        assert(abs(v.x - want[i][0]) < 1e-4 && abs(v.y - want[i][1]) < 1e-4
               && abs(v.z - want[i][2]) < 1e-4,
               format("%s: v%s at (%.6f, %.6f, %.6f), captured (%(%.6f, %)); the rival: %s",
                      cell, i, v.x, v.y, v.z, want[i][], rival));
}

unittest { // KFH_TS_V — the first step (5,-3) is a 0.01 / -0.01 tie: Z wins, v0 z -0.1
    if (!runs("ts_v")) return;
    const at = rig(kSquare, Vec3(0.2977f, 0, 0.1979f));
    ctrlDrag(at, round1());
    expect("ts_v", [[0.2977, 0, 0.0979], [0.4977, 0, 0.1979], [0.4977, 0, 0.3979], [0.2977, 0, 0.3979]],
           "a tie to the lower axis moves v0 x +0.155; the raw delta lands z 0.102343");
}

unittest { // KFH_TS_E — the edge v0-v3 grabbed at z 0.298048: both ends z -0.1
    if (!runs("ts_e")) return;
    const at = rig(kSquare, Vec3(0.2977f, 0, 0.298047538f));
    ctrlDrag(at, round1());
    expect("ts_e", [[0.2977, 0, 0.0979], [0.4977, 0, 0.1979], [0.4977, 0, 0.3979], [0.2977, 0, 0.2979]],
           "the rail slide moves both ends along x");
}

unittest { // KFH_TS_VSK — first step (6,-1) elects X on a skewed quad: v0 x +0.155
    if (!runs("ts_vsk")) return;
    const at = rig(kSkew, Vec3(0.2977f, 0, 0.1979f));
    ctrlDrag(at, round2());
    expect("ts_vsk", [[0.4527, 0, 0.1979], [0.4977, 0, 0.2979], [0.4477, 0, 0.4979], [0.2477, 0, 0.3979]],
           "the rail slide along v0->v1 lands (0.436336, 0, 0.267218); a free move z 0.0979");
}

unittest { // KFH_TS_ESK — the skewed edge v0-v3 at its press foot: both ends x +0.155
    if (!runs("ts_esk")) return;
    const at = rig(kSkew, Vec3(0.272684142f, 0, 0.297963412f));
    ctrlDrag(at, round2());
    expect("ts_esk", [[0.4527, 0, 0.1979], [0.4977, 0, 0.2979], [0.4477, 0, 0.4979], [0.4027, 0, 0.3979]],
           "the rail slide moves the ends along (0.894, 0, 0.447)");
}

// Ours-extrapolated world-axis regression (9528), not a new reference capture.
// Ry(90)*S(2,3,0.5): world = (0.3+0.5*local.z, 3*local.y, 0.2-2*local.x).
// q=0.005 at H=(0.3,0,0.2): first (6,-3) gives world (0.015,0,-0.005),
// local (0.0025,0,0.03). WORLD X wins; the mutant electing LOCAL Z differs.
unittest {
    if (!runs("transformed_primary")) return;
    const at = rig([[0.0,0,0], [0.2,0,0], [0.2,0,0.2], [0.0,0,0.2]], Vec3(0.3f, 0, 0.2f), true);
    ctrlDrag(at, [[6,-3], [64,-39]]); // total (70,-42): world DQ (0.16,0,-0.095)
    auto local = readVerts(); // /api/model publishes the primary's layer-local mesh.
    assert(local.length == 4, "transformed-primary: keep the quad's four vertices");
    const Vec3 worldV0 = Vec3(0.3f + 0.5f * local[0].z, 3 * local[0].y, 0.2f - 2 * local[0].x);
    const worldError = worldV0 - Vec3(0.46f, 0, 0.2f);
    assert(dot(worldError, worldError) < 1e-8f,
           format("transformed-primary: elect WORLD X, v0 world (0.46,0,0.2); got %s", worldV0));
    const localError = local[0] - Vec3(0, 0, 0.32f);
    assert(dot(localError, localError) < 1e-8f,
           format("transformed-primary: WORLD X +0.16 round-trips to LOCAL Z +0.32; got %s", local[0]));
    const Vec3[3] unchanged = [Vec3(0.2f,0,0), Vec3(0.2f,0,0.2f), Vec3(0,0,0.2f)];
    foreach (i, v; unchanged) {
        const error = local[i + 1] - v;
        assert(dot(error, error) < 1e-8f,
               format("transformed-primary: ungrabbed v%s stays LOCAL %s; got %s", i + 1, v, local[i + 1]));
    }
}
