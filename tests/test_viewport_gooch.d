// The Gooch display style (viewport shading S4a, task 9150): cool-to-warm tone
// shading, `out = min(mix(kcool, kwarm, |N·Lg|), 1)` with
// kcool = (0,0,0.35) + 0.2·Kd, kwarm = (0.44,0.44,0) + 0.6·Kd, Kd = base colour
// × diffuse amount, Lg = (1,1,1)/√3 in EYE space, no specular. Every
// prediction is computed here from that formula (an independent copy of
// `light_rig`'s Gooch constants), with eye-space normals placed through the
// LIVE view matrix.
//
// Cells: (a) three flat quads whose eye normals are Lg, ⟂Lg and −Lg read
// kwarm, kcool and kwarm (abs: −Lg separates abs from max(…,0)), plus a
// camera-facing quad at |N·Lg| = 1/√3 (the mix is linear in |N·L|); (b) the
// same eye normals rebuilt under a 90° camera roll read the same — and a light
// fixed in the world (the base view's Lg) would not. `VIBE3D_CELL=<id>` runs
// one cell.

import http_client : getJson, postJson, frameFence;
import http_command_helpers : commandBody;
import drag_helpers;

import std.format : format;
import std.json : JSONType, JSONValue;
import std.math : abs, sqrt, PI;
import std.stdio : writefln;

void main() {}

bool cellOn(string id) {
    import std.process : environment;
    immutable e = environment.get("VIBE3D_CELL", "");
    return e.length == 0 || e == id;
}

void cmd(string script) {
    auto r = postJson("/api/command", script);
    assert(r["status"].str == "ok", "/api/command failed for " ~ script ~ ": " ~ r.toString);
}

void runCmd(string id, string paramsJson) {
    auto r = postJson("/api/command", `{"id":"` ~ id ~ `","params":` ~ paramsJson ~ `}`);
    assert(r["status"].str == "ok", id ~ " failed: " ~ r.toString);
}

// ---------------------------------------------------------------------------
// The law, in doubles, from its captured definition.
// ---------------------------------------------------------------------------
alias D3 = double[3];
D3 nrm(D3 v) { immutable l = sqrt(v[0]^^2 + v[1]^^2 + v[2]^^2); return [v[0]/l, v[1]/l, v[2]/l]; }
double dot3(D3 a, D3 b) { return a[0]*b[0] + a[1]*b[1] + a[2]*b[2]; }
D3 add3(D3 a, D3 b) { return [a[0]+b[0], a[1]+b[1], a[2]+b[2]]; }

immutable D3 kLg = [0.57735026919, 0.57735026919, 0.57735026919];
immutable D3 kCool = [0.0, 0.0, 0.35];
immutable D3 kWarm = [0.44, 0.44, 0.0];
enum double kCoolKd = 0.2, kWarmKd = 0.6;

/// Base colour 0.6 grey at diffuse amount 0.8: Kd = 0.48 on every channel.
enum double kBase = 0.6, kAmount = 0.8;

/// 0..255 RGB of the Gooch tone at blend `t` (= the |N·L| or the max(N·L,0)).
double[3] toneAt(double t, double kd = kBase * kAmount) {
    double[3] o;
    foreach (c; 0 .. 3) {
        immutable double cool = kCool[c] + kCoolKd * kd, warm = kWarm[c] + kWarmKd * kd;
        double v = cool + (warm - cool) * t;
        if (v > 1) v = 1;
        o[c] = 255.0 * v;
    }
    return o;
}
/// The law: two-sided abs.
double[3] gooch(D3 nEye, D3 light = kLg) { return toneAt(abs(dot3(nrm(nEye), light))); }
/// The losing candidate: one-sided max(N·L, 0).
double[3] goochMax(D3 nEye) { immutable d = dot3(nrm(nEye), kLg); return toneAt(d > 0 ? d : 0); }

double maxGap(double[3] a, double[3] b) {
    double g = 0;
    foreach (c; 0 .. 3) if (abs(a[c] - b[c]) > g) g = abs(a[c] - b[c]);
    return g;
}

// ---------------------------------------------------------------------------
// Live camera, probes, scene loading (the light-rig suite's rig).
// ---------------------------------------------------------------------------
D3 toEye(const ref Viewport vp, D3 w) {
    return [vp.view[0]*w[0] + vp.view[4]*w[1] + vp.view[8]*w[2],
            vp.view[1]*w[0] + vp.view[5]*w[1] + vp.view[9]*w[2],
            vp.view[2]*w[0] + vp.view[6]*w[1] + vp.view[10]*w[2]];
}
D3 toWorld(const ref Viewport vp, D3 e) {
    return [vp.view[0]*e[0] + vp.view[1]*e[1] + vp.view[2]*e[2],
            vp.view[4]*e[0] + vp.view[5]*e[1] + vp.view[6]*e[2],
            vp.view[8]*e[0] + vp.view[9]*e[1] + vp.view[10]*e[2]];
}

/// The rig sits 3 m above the grid plane, clear of the grid's lines.
immutable D3 kC = [0.0, 3.0, 0.0];

void setCamera(double az, double el, double dist, double roll = 0) {
    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"roll":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        az, el, dist, roll, kC[0], kC[1], kC[2]));
    frameFence(null, 2);
}

void restoreCamera(const ref Viewport vp, double az, double el, double dist, double roll) {
    setCamera(az, el, dist, roll);
    auto now = viewportFromCameraMatrices();
    foreach (i; 0 .. 16)
        assert(abs(now.view[i] - vp.view[i]) < 1e-5, "rig: the camera did not come back after the load");
}

int[2] cellPx(const ref Viewport vp, D3 w) {
    float px, py;
    assert(projectToWindow(Vec3(cast(float)w[0], cast(float)w[1], cast(float)w[2]), vp, px, py),
        format("rig: %s is behind the camera", w));
    return [cast(int)(px + 0.5f) - vp.x, cast(int)(py + 0.5f) - vp.y];
}

/// RGB at cell-0 pixels `pts`.
int[3][] probeRGB(int[2][] pts) {
    string q;
    foreach (i, p; pts) q ~= format("%s%d,%d", i ? ";" : "", p[0], p[1]);
    auto j = getJson(format("/api/viewport/probe?cell=0&points=%s", q));
    assert(j["renders"].type == JSONType.true_, "probe: cell 0 must be rendering");
    int[3][] r;
    foreach (e; j["points"].array) {
        assert(("error" in e) is null, "probe point refused: " ~ e.toString);
        r ~= [cast(int)e["r"].integer, cast(int)e["g"].integer, cast(int)e["b"].integer];
    }
    return r;
}

private int g_rig = 0;

/// One mesh layer of quads, one surface (base kBase, diffuse kAmount, no
/// specular), drawn in the Gooch style with no overlay.
void loadQuads(D3[] verts, uint[][] faces) {
    import std.file : write, remove, exists, tempDir;
    import std.path : buildPath;
    import std.process : thisProcessID;
    string vs, fs, ms;
    foreach (i, v; verts) vs ~= format("%s[%.9g,%.9g,%.9g]", i ? "," : "", v[0], v[1], v[2]);
    foreach (i, f; faces) {
        fs ~= i ? ",[" : "[";
        foreach (j, x; f) fs ~= format("%s%d", j ? "," : "", x);
        fs ~= "]";
        ms ~= format("%s0", i ? "," : "");
    }
    immutable surf = format(`{"name":"G","baseColor":[%.9g,%.9g,%.9g],"diffuse":%.9g,`
        ~ `"specular":0,"glossiness":0.4,"opacity":1}`, kBase, kBase, kBase, kAmount);
    immutable path = buildPath(tempDir(), format("vibe3d-gooch-%d-%d.v3d", thisProcessID(), g_rig++));
    write(path, `{"formatVersion":8,"primaryLayer":0,"focusedItem":0,"layers":[{"type":"mesh",`
        ~ `"selected":true,"channels":{"name":"Rig","visible":true},"mesh":{"vertices":[` ~ vs
        ~ `],"faces":[` ~ fs ~ `],"surfaces":[` ~ surf ~ `],"faceMaterial":[` ~ ms ~ `]}}]}`);
    scope(exit) if (exists(path)) remove(path);
    auto rr = postJson("/api/command", commandBody("scene.reset"));
    assert(rr["status"].str == "ok", "scene.reset failed: " ~ rr.toString);
    runCmd("file.load", format(`{"path":"%s"}`, path));
    auto m = getJson("/api/model");
    assert(m["vertices"].array.length == verts.length && m["faces"].array.length == faces.length,
        format("rig: loaded %d verts / %d faces, wrote %d / %d", m["vertices"].array.length,
               m["faces"].array.length, verts.length, faces.length));
    cmd("viewport.wireOverlay none");
    cmd("select.typeFrom polygon");
    cmd(commandBody("viewport.displayStyle", `{"value":"gooch"}`));
    auto plan = getJson("/api/viewport/display")["cells"].array[0]["plan"]["active"];
    assert(plan["shading"].str == "Gooch" && plan["drawFaces"].type == JSONType.true_,
        "rig premise: cell 0's active plan must be the Gooch arm: " ~ plan.toString);
    frameFence(null, 2);
}

/// A square of half-size `h` centred at world `c` with world unit normal `n`.
void quadAt(D3 c, D3 n, double h, ref D3[] v, ref uint[][] f) {
    D3 up = abs(n[1]) < 0.9 ? [0.0, 1.0, 0.0] : [1.0, 0.0, 0.0];
    D3 u = nrm([up[1]*n[2]-up[2]*n[1], up[2]*n[0]-up[0]*n[2], up[0]*n[1]-up[1]*n[0]]);
    D3 w = [n[1]*u[2]-n[2]*u[1], n[2]*u[0]-n[0]*u[2], n[0]*u[1]-n[1]*u[0]];
    immutable uint b = cast(uint) v.length;
    foreach (s; [[-1.0, -1.0], [1.0, -1.0], [1.0, 1.0], [-1.0, 1.0]])
        v ~= [c[0] + h*(s[0]*u[0] + s[1]*w[0]), c[1] + h*(s[0]*u[1] + s[1]*w[1]),
              c[2] + h*(s[0]*u[2] + s[1]*w[2])];
    f ~= [b, b + 1, b + 2, b + 3];
}

// The four eye-space normals: toward Lg, perpendicular to it (front-facing),
// away from it (we see the quad's back), and toward the camera.
immutable D3[] kNEye = [
    [0.57735026919, 0.57735026919, 0.57735026919],
    [-0.40824829046, -0.40824829046, 0.81649658093],
    [-0.57735026919, -0.57735026919, -0.57735026919],
    [0.0, 0.0, 1.0],
];
immutable string[] kNames = ["toward Lg", "perpendicular", "away from Lg (-Lg)", "camera-facing"];
immutable D3[] kCentresEye = [[-1.2, 0.9, 0], [1.2, 0.9, 0], [-1.2, -0.9, 0], [1.2, -0.9, 0]];

/// Build the four quads against `vp`, load them, put the camera back, probe.
int[3][] buildAndProbe(const ref Viewport vp, double az, double el, double dist, double roll) {
    D3[] v; uint[][] f; D3[] cw;
    foreach (k; 0 .. 4) {
        immutable D3 c = add3(kC, toWorld(vp, kCentresEye[k]));
        cw ~= c;
        quadAt(c, nrm(toWorld(vp, kNEye[k])), 0.45, v, f);
    }
    loadQuads(v, f);
    restoreCamera(vp, az, el, dist, roll);
    int[2][] pts;
    foreach (c; cw) pts ~= cellPx(vp, c);
    return probeRGB(pts);
}

void assertReads(string cell, int[3][] got, double[3][] pred) {
    foreach (k; 0 .. 4) {
        writefln("[gooch %s] %s: read (%d,%d,%d), predicted (%.2f,%.2f,%.2f)", cell, kNames[k],
                 got[k][0], got[k][1], got[k][2], pred[k][0], pred[k][1], pred[k][2]);
        foreach (c; 0 .. 3)
            assert(abs(got[k][c] - pred[k][c]) <= 1, format("(%s) the %s quad reads (%d,%d,%d), "
                ~ "the Gooch law predicts (%.2f,%.2f,%.2f) (+-1 level)", cell, kNames[k],
                got[k][0], got[k][1], got[k][2], pred[k][0], pred[k][1], pred[k][2]));
    }
}

// ---------------------------------------------------------------------------
// (a) warm / cool / warm (abs) / the linear mid-point, at a non-trivial view.
// ---------------------------------------------------------------------------
unittest {
    if (!cellOn("a")) return;
    enum double az = 0.35, el = 0.25, dist = 8.0;
    setCamera(az, el, dist);
    auto vp = viewportFromCameraMatrices();
    // Predictions, then their premises and discrimination floors.
    double[3][] pred;
    foreach (n; kNEye) pred ~= gooch(n);
    assert(abs(dot3(kNEye[1], kLg)) < 1e-9 && kNEye[3][2] > 0 && kNEye[1][2] > 0,
        "(a) premise: the perpendicular normal is ⟂Lg and front-facing");
    assert(maxGap(pred[0], pred[1]) >= 6 && maxGap(pred[3], pred[0]) >= 6
           && maxGap(pred[3], pred[1]) >= 6,
        format("(a) floor: warm %s, cool %s and the mid-point %s must be ≥ 6 levels apart",
               pred[0], pred[1], pred[3]));
    // abs vs max(…,0): the −Lg quad separates them (warm vs cool).
    assert(maxGap(gooch(kNEye[2]), goochMax(kNEye[2])) >= 6,
        "(a) floor: the −Lg quad cannot tell abs from max(N·L,0)");
    // Cool vs warm swapped would read the mirrored mix: the floor is the warm/cool gap above.
    writefln("[gooch a] kwarm (%.2f,%.2f,%.2f) kcool (%.2f,%.2f,%.2f); max(N·L,0) at −Lg: (%.2f,%.2f,%.2f)",
             pred[0][0], pred[0][1], pred[0][2], pred[1][0], pred[1][1], pred[1][2],
             goochMax(kNEye[2])[0], goochMax(kNEye[2])[1], goochMax(kNEye[2])[2]);
    scope(exit) postJson("/api/command", commandBody("viewport.displayStyle", `{"value":"shaded"}`));
    assertReads("a", buildAndProbe(vp, az, el, dist, 0), pred);
}

// ---------------------------------------------------------------------------
// (b) the light is an EYE-space constant: the same eye normals rebuilt under a
// 90° camera roll read the same. Counterfactual floor: a light fixed in the
// world at the base view's Lg predicts ≥ 6 levels off on at least one quad.
// ---------------------------------------------------------------------------
unittest {
    if (!cellOn("b")) return;
    enum double az = 0.35, el = 0.25, dist = 8.0, roll = PI / 2;
    setCamera(az, el, dist);
    auto vp0 = viewportFromCameraMatrices();
    setCamera(az, el, dist, roll);
    auto vp = viewportFromCameraMatrices();
    immutable D3 lWorld = toWorld(vp0, kLg);
    immutable D3 lRolled = toEye(vp, lWorld);
    double[3][] pred;
    double gap = 0;
    foreach (n; kNEye) {
        pred ~= gooch(n);
        immutable g = maxGap(gooch(n), gooch(n, lRolled));
        if (g > gap) gap = g;
    }
    assert(gap >= 6, format("(b) floor: a world-fixed light moves the quads by only %.2f levels", gap));
    writefln("[gooch b] roll 90: a world-fixed light would move a quad by %.2f levels", gap);
    scope(exit) postJson("/api/command", commandBody("viewport.displayStyle", `{"value":"shaded"}`));
    assertReads("b", buildAndProbe(vp, az, el, dist, roll), pred);
}
