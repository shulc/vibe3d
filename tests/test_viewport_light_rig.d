// The viewport's light rig (viewport shading S1b, task 9130): two directional
// lights that are CONSTANTS IN EYE SPACE (key upper-left toward the viewer,
// fill screen-right), the levels `Kd·(0.15 + 0.7·max(N·key,0) +
// 0.3·max(N·fill,0))` with Kd = base colour × diffuse amount, and a Blinn
// specular from the material with the viewer at infinity. Every prediction is
// computed here from that formula (an independent copy of `light_rig`), with
// the eye-space normal taken through the LIVE view matrix.
//
// Cells: (i) camera turns about a smooth sphere leave its image unchanged (and
// the old world-fixed rig predicts that they would not); (ii) the brightest
// pixel sits in the key+fill quadrant; (iii) levels at four known normals;
// (iv) the diffuse amount scales ambient AND diffuse (the losing candidates are
// the discrimination floor); (v) the specular term: amount, exponent table and
// the viewer at infinity. `VIBE3D_CELL=<id>` runs one cell.

import http_client : getJson, postJson, frameFence;
import http_command_helpers : commandBody;
import drag_helpers;

import std.conv : to;
import std.format : format;
import std.json : JSONType, JSONValue;
import std.math : abs, sqrt, pow, PI, cos, sin;
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
// The rig, in doubles, from its captured definition.
// ---------------------------------------------------------------------------
alias D3 = double[3];
D3 nrm(D3 v) { immutable l = sqrt(v[0]^^2 + v[1]^^2 + v[2]^^2); return [v[0]/l, v[1]/l, v[2]/l]; }
double dot3(D3 a, D3 b) { return a[0]*b[0] + a[1]*b[1] + a[2]*b[2]; }
D3 add3(D3 a, D3 b) { return [a[0]+b[0], a[1]+b[1], a[2]+b[2]]; }

// key = (−sin a·cos b, −sin b, cos a·cos b) at (0.9424778, −0.6283185); fill (1,0,0).
immutable D3 kKey  = [-0.654509, 0.587785, 0.475528];
immutable D3 kFill = [1.0, 0.0, 0.0];
enum double kKeyI = 0.7, kFillI = 0.3, kAmb = 0.15;

/// The captured exponent table (roughness -> Blinn exponent) at its samples.
double specPowerAt(double rough) {
    if (rough <= 0.48) return 128.0;
    immutable double[2][] t = [[0.5, 121.847458], [0.6, 76.322327], [0.7, 49.638916],
                               [0.8, 33.260273], [0.9, 22.834875], [1.0, 16.0]];
    foreach (s; t) if (abs(s[0] - rough) < 1e-9) return s[1];
    assert(false, format("specPowerAt: %s is not a captured sample", rough));
}

/// 0..255 level of one channel: base colour `base`, diffuse amount `amt`,
/// specular amount `spec`, exponent `p`, at EYE-space unit normal `n`, with the
/// viewer at infinity (H = normalize(L + ẑ)), spec gated by N·L > 0.
double level(double base, double amt, double spec, double p, D3 n) {
    immutable N = nrm(n);
    immutable double nk = dot3(N, kKey), nf = dot3(N, kFill);
    immutable double dif = kKeyI * (nk > 0 ? nk : 0) + kFillI * (nf > 0 ? nf : 0);
    double s = 0;
    if (nk > 0) s += kKeyI  * pow(dot3(N, nrm(add3(kKey,  [0, 0, 1]))) > 0 ? dot3(N, nrm(add3(kKey,  [0, 0, 1]))) : 0, p);
    if (nf > 0) s += kFillI * pow(dot3(N, nrm(add3(kFill, [0, 0, 1]))) > 0 ? dot3(N, nrm(add3(kFill, [0, 0, 1]))) : 0, p);
    double c = base * amt * (kAmb + dif) + spec * s;
    if (c > 1) c = 1;
    return 255.0 * c;
}

/// The pre-task-9130 world-fixed rig (normalize(0.6,1,0.5) world, ambient 0.2
/// unscaled, spec 0.25·pow(N·H,32) with a local viewer), base 0.8: the
/// COUNTERFACTUAL cell (i) must be able to tell from the new rig.
double oldLevel(D3 nWorld, D3 pWorld, D3 eye) {
    immutable L = nrm([0.6, 1.0, 0.5]);
    immutable V = nrm([eye[0]-pWorld[0], eye[1]-pWorld[1], eye[2]-pWorld[2]]);
    immutable H = nrm(add3(L, V));
    immutable N = nrm(nWorld);
    immutable dif = dot3(N, L) > 0 ? dot3(N, L) : 0;
    double c = 0.8 * (0.2 + dif * 0.8) + pow(dot3(N, H) > 0 ? dot3(N, H) : 0, 32.0) * 0.25;
    if (c > 1) c = 1;
    return 255.0 * c;
}

// ---------------------------------------------------------------------------
// Live camera: world <-> eye directions, pixel rays, probes.
// ---------------------------------------------------------------------------
/// World direction -> eye direction (the view's rotation rows).
D3 toEye(const ref Viewport vp, D3 w) {
    return [vp.view[0]*w[0] + vp.view[4]*w[1] + vp.view[8]*w[2],
            vp.view[1]*w[0] + vp.view[5]*w[1] + vp.view[9]*w[2],
            vp.view[2]*w[0] + vp.view[6]*w[1] + vp.view[10]*w[2]];
}
/// Eye direction -> world direction (transpose).
D3 toWorld(const ref Viewport vp, D3 e) {
    return [vp.view[0]*e[0] + vp.view[1]*e[1] + vp.view[2]*e[2],
            vp.view[4]*e[0] + vp.view[5]*e[1] + vp.view[6]*e[2],
            vp.view[8]*e[0] + vp.view[9]*e[1] + vp.view[10]*e[2]];
}

/// Every rig sits around this point, 3 m above the grid plane: the grid's
/// lines (its axis lines drawn bold) would otherwise cross in front of the
/// lower half of a mesh at the origin seen from above.
immutable D3 kC = [0.0, 3.0, 0.0];

void setCamera(double az, double el, double dist, double roll = 0) {
    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"roll":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        az, el, dist, roll, kC[0], kC[1], kC[2]));
    frameFence(null, 2);
}

/// `scene.reset` (inside `loadMesh`) resets the camera: re-apply the rig's
/// camera and check it is the one the geometry was built against.
void restoreCamera(const ref Viewport vp, double az, double el, double dist) {
    setCamera(az, el, dist);
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

/// Red channel at cell-0 pixels `pts`.
int[] probeR(int[2][] pts) {
    string q;
    foreach (i, p; pts) q ~= format("%s%d,%d", i ? ";" : "", p[0], p[1]);
    auto j = getJson(format("/api/viewport/probe?cell=0&points=%s", q));
    assert(j["renders"].type == JSONType.true_, "probe: cell 0 must be rendering");
    int[] r;
    foreach (e; j["points"].array) {
        assert(("error" in e) is null, "probe point refused: " ~ e.toString);
        r ~= cast(int)e["r"].integer;
    }
    return r;
}

// ---------------------------------------------------------------------------
// Scene loading: one mesh layer, optional surfaces + per-face material.
// ---------------------------------------------------------------------------
private int g_rig = 0;

struct Surf { double base, diffuse, specular, gloss; }

void loadMesh(D3[] verts, uint[][] faces, Surf[] surfs = null, uint[] faceMat = null) {
    import std.file : write, remove, exists, tempDir;
    import std.path : buildPath;
    import std.process : thisProcessID;
    string vs, fs, ss, ms;
    foreach (i, v; verts) vs ~= format("%s[%.9g,%.9g,%.9g]", i ? "," : "", v[0], v[1], v[2]);
    foreach (i, f; faces) {
        fs ~= i ? ",[" : "[";
        foreach (j, x; f) fs ~= format("%s%d", j ? "," : "", x);
        fs ~= "]";
    }
    string extra;
    if (surfs.length) {
        foreach (i, s; surfs)
            ss ~= format(`%s{"name":"S%d","baseColor":[%.9g,%.9g,%.9g],"diffuse":%.9g,`
                ~ `"specular":%.9g,"glossiness":%.9g,"opacity":1}`, i ? "," : "", i,
                s.base, s.base, s.base, s.diffuse, s.specular, s.gloss);
        foreach (i, m; faceMat) ms ~= format("%s%d", i ? "," : "", m);
        extra = `,"surfaces":[` ~ ss ~ `],"faceMaterial":[` ~ ms ~ `]`;
    }
    immutable path = buildPath(tempDir(), format("vibe3d-light-rig-%d-%d.v3d", thisProcessID(), g_rig++));
    write(path, `{"formatVersion":8,"primaryLayer":0,"focusedItem":0,"layers":[{"type":"mesh",`
        ~ `"selected":true,"channels":{"name":"Rig","visible":true},"mesh":{"vertices":[` ~ vs
        ~ `],"faces":[` ~ fs ~ `]` ~ extra ~ `}}]}`);
    scope(exit) if (exists(path)) remove(path);
    auto rr = postJson("/api/command", commandBody("scene.reset"));
    assert(rr["status"].str == "ok", "scene.reset failed: " ~ rr.toString);
    runCmd("file.load", format(`{"path":"%s"}`, path));
    auto m = getJson("/api/model");
    assert(m["vertices"].array.length == verts.length && m["faces"].array.length == faces.length,
        format("rig: loaded %d verts / %d faces, wrote %d / %d", m["vertices"].array.length,
               m["faces"].array.length, verts.length, faces.length));
    cmd("viewport.wireOverlay none");
    // Vertex selection mode draws every vertex as a 3 px base dot; a probe
    // must read the surface.
    cmd("select.typeFrom polygon");
    frameFence(null, 2);
}

/// A UV sphere of radius 1 at `kC`, poles on Y, wound outward.
void uvSphere(int segs, int rings, out D3[] v, out uint[][] f) {
    v ~= add3(kC, [0.0, 1.0, 0.0]);
    foreach (k; 1 .. rings) {
        immutable double lat = PI / 2 - PI * k / rings;
        foreach (j; 0 .. segs) {
            immutable double lon = 2 * PI * j / segs;
            v ~= [kC[0] + cos(lat) * sin(lon), kC[1] + sin(lat), kC[2] + cos(lat) * cos(lon)];
        }
    }
    v ~= add3(kC, [0.0, -1.0, 0.0]);
    uint at(int k, int j) { return cast(uint)(1 + (k - 1) * segs + (j % segs)); }
    immutable uint bottom = cast(uint)(v.length - 1);
    // Outward from +Y looking down: (top, next, this) is counter-clockwise from outside.
    foreach (j; 0 .. segs) f ~= [0u, at(1, j), at(1, j + 1)];
    foreach (k; 1 .. rings - 1)
        foreach (j; 0 .. segs) f ~= [at(k, j), at(k + 1, j), at(k + 1, j + 1), at(k, j + 1)];
    foreach (j; 0 .. segs) f ~= [bottom, at(rings - 1, j + 1), at(rings - 1, j)];
    foreach (ref face; f) {
        D3 c = [0, 0, 0];
        foreach (x; face) c = add3(c, [v[x][0] - kC[0], v[x][1] - kC[1], v[x][2] - kC[2]]);
        D3 a = v[face[0]], b = v[face[1]], d = v[face[2]];
        D3 e1 = [b[0]-a[0], b[1]-a[1], b[2]-a[2]], e2 = [d[0]-a[0], d[1]-a[1], d[2]-a[2]];
        D3 n = [e1[1]*e2[2]-e1[2]*e2[1], e1[2]*e2[0]-e1[0]*e2[2], e1[0]*e2[1]-e1[1]*e2[0]];
        if (dot3(n, c) < 0) { import std.algorithm : reverse; face.reverse(); }
    }
}

/// A square of half-size `h` centred at world `c` with world unit normal `n`,
/// wound counter-clockwise about `n`.
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

// ---------------------------------------------------------------------------
// (i) the rig turns with the camera. A smooth 64x32 sphere at the focus,
// camera turned about its centre by roll 90°, pitch 80°, heading +90°: every
// probe inside the disc reads its base value (±2). The counterfactual (the old
// world-fixed rig, computed from the ray-sphere normal) moves ≥ 25 % of them
// by > 8 levels — the floor that makes "unchanged" mean something.
// ---------------------------------------------------------------------------
unittest {
    if (!cellOn("i")) return;
    D3[] v; uint[][] f;
    uvSphere(64, 32, v, f);
    loadMesh(v, f);
    enum double dist = 4.0, el0 = 0.3;
    setCamera(0, el0, dist);
    auto vp0 = viewportFromCameraMatrices();
    // Probe grid: the projected disc of the sphere, 0.8 of its pixel radius, on
    // half-step offsets — no point on the centre row or column, where a
    // screen-centred overlay line (3 px, drawn over the surface) would sit
    // in one view and not in the rolled one.
    immutable int[2] c0 = cellPx(vp0, kC);
    immutable double rPx = 1.0 / dist * vp0.proj[5] * vp0.height / 2;  // ≈ (r/d)·f
    int[2][] pts;
    foreach (iy; -5 .. 5) foreach (ix; -5 .. 5) {
        immutable double dx = (ix + 0.5) * 0.16 * rPx, dy = (iy + 0.5) * 0.16 * rPx;
        if (dx * dx + dy * dy > (0.8 * rPx) ^^ 2) continue;
        pts ~= [c0[0] + cast(int) dx, c0[1] + cast(int) dy];
    }
    // Floor on the classified-inside count [E4]: 10x10 half-step grid inside
    // a disc of radius 5 steps.
    assert(pts.length >= 40, format("(i) floor: only %d probe points inside the disc", pts.length));
    assert(rPx >= 60, format("(i) rig: the sphere is only %.0f px in radius", rPx));
    writefln("[light rig (i)] %d probe points, disc radius %.0f px", pts.length, rPx);
    const base = probeR(pts);

    /// The world normal at the sphere point under pixel `p` for camera `vp`.
    bool hit(const ref Viewport vp, int[2] p, out D3 n) {
        Vec3 org, dir;
        pixelRay(p[0] + vp.x + 0.5f, p[1] + vp.y + 0.5f, vp, org, dir);
        immutable D3 o = [org.x - kC[0], org.y - kC[1], org.z - kC[2]], d = [dir.x, dir.y, dir.z];
        immutable double b = dot3(o, d), cc = dot3(o, o) - 1;
        immutable double disc = b * b - cc;
        if (disc < 0) return false;
        immutable double t = -b - sqrt(disc);
        n = nrm([o[0] + t*d[0], o[1] + t*d[1], o[2] + t*d[2]]);
        return true;
    }
    immutable double[3][] cams = [[0, el0, PI / 2], [0, 80 * PI / 180, 0], [PI / 2, el0, 0]];
    immutable string[] names = ["roll 90", "pitch 80", "heading +90"];
    foreach (ci, cam; cams) {
        setCamera(cam[0], cam[1], dist, cam[2]);
        auto vp = viewportFromCameraMatrices();
        // Counterfactual: the world-fixed rig's prediction at each point.
        size_t moved, both;
        foreach (p; pts) {
            D3 n0, n1;
            if (!hit(vp0, p, n0) || !hit(vp, p, n1)) continue;
            ++both;
            immutable D3 e0 = [vp0.eye.x, vp0.eye.y, vp0.eye.z], e1 = [vp.eye.x, vp.eye.y, vp.eye.z];
            if (abs(oldLevel(n0, add3(kC, n0), e0) - oldLevel(n1, add3(kC, n1), e1)) > 8) ++moved;
        }
        assert(both == pts.length, format("(i) %s: %d of %d probe rays miss the sphere",
                                          names[ci], pts.length - both, pts.length));
        assert(moved * 4 >= pts.length, format("(i) %s discrimination floor: the world-fixed rig "
            ~ "moves only %d of %d points by > 8 levels", names[ci], moved, pts.length));
        const got = probeR(pts);
        size_t worst; int worstD;
        foreach (k; 0 .. pts.length) if (abs(got[k] - base[k]) > worstD) { worstD = abs(got[k] - base[k]); worst = k; }
        writefln("[light rig (i)] %s: max |delta| %d over %d points (world-fixed would move %d)",
                 names[ci], worstD, pts.length, moved);
        assert(worstD <= 2, format("(i) %s: point %s reads %d, base %d — the light must turn "
            ~ "with the camera (eye-space rig)", names[ci], pts[worst], got[worst], base[worst]));
    }
}

// ---------------------------------------------------------------------------
// (ii) the brightest of a 9x9 grid over the sphere sits in the screen quadrant
// of normalize(0.7·key + 0.3·fill).xy = upper left — at the base view and
// under a 90° roll (screen-relative, so still upper left).
// ---------------------------------------------------------------------------
unittest {
    if (!cellOn("ii")) return;
    D3[] v; uint[][] f;
    uvSphere(64, 32, v, f);
    loadMesh(v, f);
    immutable D3 comb = nrm(add3([kKeyI*kKey[0], kKeyI*kKey[1], kKeyI*kKey[2]],
                                 [kFillI*kFill[0], kFillI*kFill[1], kFillI*kFill[2]]));
    assert(comb[0] < -0.1 && comb[1] > 0.1, format("(ii) premise: key+fill %s is not upper-left", comb));
    foreach (roll; [0.0, PI / 2]) {
        setCamera(0.4, 0.3, 4.0, roll);
        auto vp = viewportFromCameraMatrices();
        immutable int[2] c = cellPx(vp, kC);
        immutable double rPx = 1.0 / 4.0 * vp.proj[5] * vp.height / 2;
        int[2][] pts;
        foreach (iy; -4 .. 5) foreach (ix; -4 .. 5)
            pts ~= [c[0] + cast(int)(ix * 0.22 * rPx), c[1] + cast(int)(iy * 0.22 * rPx)];
        const r = probeR(pts);
        size_t best;
        foreach (k; 0 .. r.length) if (r[k] > r[best]) best = k;
        writefln("[light rig (ii)] roll %.2f: brightest %d at %s (centre %s)", roll, r[best], pts[best], c);
        assert(pts[best][0] < c[0] && pts[best][1] < c[1],
            format("(ii) roll %.2f: the brightest probe %s (%d) is not upper-left of the centre %s",
                   roll, pts[best], r[best], c));
    }
}

// ---------------------------------------------------------------------------
// (iii) levels: four flat quads whose EYE-space normals are chosen against the
// rig — camera-facing, ambient only, key-facing, fill-dominant — base 0.6,
// diffuse amount 0.8 (Kd 0.48), no specular.
// ---------------------------------------------------------------------------
unittest {
    if (!cellOn("iii")) return;
    setCamera(0.35, 0.25, 8.0);
    auto vp = viewportFromCameraMatrices();
    D3[] nEye;
    nEye ~= [0.0, 0.0, 1.0];
    nEye ~= nrm([-0.2, -0.9, 0.4]);
    nEye ~= kKey;
    nEye ~= nrm([0.8, 0.0, 0.6]);
    immutable string[] names = ["facing", "ambient-only", "key-facing", "fill-dominant"];
    // Prediction table first, with its discrimination floor (each level ≥ 6
    // from every other, so a swapped quad cannot pass).
    double[] pred;
    foreach (n; nEye) pred ~= level(0.6, 0.8, 0, 1, n);
    foreach (a; 0 .. 4) foreach (b; a + 1 .. 4)
        assert(abs(pred[a] - pred[b]) >= 6, format("(iii) floor: %s and %s predict %.2f / %.2f",
                                                 names[a], names[b], pred[a], pred[b]));
    // Ambient-only premise: N·key ≤ 0 and N·fill ≤ 0.
    assert(dot3(nEye[1], kKey) <= 0 && dot3(nEye[1], kFill) <= 0, "(iii) premise: not ambient-only");
    D3[] v; uint[][] f;
    immutable D3[] centresEye = [[-1.2, 0.9, 0], [1.2, 0.9, 0], [-1.2, -0.9, 0], [1.2, -0.9, 0]];
    D3[] cw;
    foreach (k; 0 .. 4) {
        // A centre in the focus plane, offset along the camera's right/up.
        immutable D3 c = add3(kC, toWorld(vp, centresEye[k]));
        cw ~= c;
        quadAt(c, nrm(toWorld(vp, nEye[k])), 0.45, v, f);
    }
    loadMesh(v, f, [Surf(0.6, 0.8, 0.0, 0.4)], [0u, 0, 0, 0]);
    restoreCamera(vp, 0.35, 0.25, 8.0);
    int[2][] pts;
    foreach (c; cw) pts ~= cellPx(vp, c);
    const r = probeR(pts);
    foreach (k; 0 .. 4) {
        writefln("[light rig (iii)] %s: read %d, predicted %.2f", names[k], r[k], pred[k]);
        assert(abs(r[k] - pred[k]) <= 2, format("(iii) %s quad reads %d, the rig predicts %.2f (+-2)",
                                              names[k], r[k], pred[k]));
    }
}

// ---------------------------------------------------------------------------
// (iv) the diffuse amount scales ambient AND diffuse (α). Two surfaces,
// amount 1.0 and 0.5 (base 0.6, no specular), each at an ambient-only and a
// key-facing normal. β (directional only) and γ (ignored) are predicted too
// and must each sit ≥ 6 levels from α on at least one amount-0.5 pixel.
// ---------------------------------------------------------------------------
unittest {
    if (!cellOn("iv")) return;
    setCamera(0.35, 0.25, 8.0);
    auto vp = viewportFromCameraMatrices();
    immutable D3 nAmb = nrm([-0.2, -0.9, 0.4]), nKey = kKey;
    double alpha(double amt, D3 n) { return level(0.6, amt, 0, 1, n); }
    double beta(double amt, D3 n) {   // amount scales the directional part only
        immutable N = nrm(n);
        immutable dif = kKeyI * (dot3(N, kKey) > 0 ? dot3(N, kKey) : 0)
                      + kFillI * (dot3(N, kFill) > 0 ? dot3(N, kFill) : 0);
        return 255.0 * 0.6 * (kAmb + amt * dif);
    }
    double gamma(double amt, D3 n) { return level(0.6, 1.0, 0, 1, n); }
    foreach (loser; [&beta, &gamma]) {
        immutable double gap = abs(alpha(0.5, nAmb) - loser(0.5, nAmb)) > abs(alpha(0.5, nKey) - loser(0.5, nKey))
            ? abs(alpha(0.5, nAmb) - loser(0.5, nAmb)) : abs(alpha(0.5, nKey) - loser(0.5, nKey));
        assert(gap >= 6, format("(iv) discrimination floor: a losing candidate is only %.2f from α", gap));
    }
    immutable D3[] centresEye = [[-1.2, 0.9, 0], [1.2, 0.9, 0], [-1.2, -0.9, 0], [1.2, -0.9, 0]];
    D3[] normals = [nAmb, nKey, nAmb, nKey];
    immutable double[] amts = [1.0, 1.0, 0.5, 0.5];
    D3[] v; uint[][] f; D3[] cw;
    foreach (k; 0 .. 4) {
        immutable D3 c = add3(kC, toWorld(vp, centresEye[k]));
        cw ~= c;
        quadAt(c, nrm(toWorld(vp, normals[k])), 0.45, v, f);
    }
    loadMesh(v, f, [Surf(0.6, 1.0, 0.0, 0.4), Surf(0.6, 0.5, 0.0, 0.4)], [0u, 0, 1, 1]);
    restoreCamera(vp, 0.35, 0.25, 8.0);
    int[2][] pts;
    foreach (c; cw) pts ~= cellPx(vp, c);
    const r = probeR(pts);
    foreach (k; 0 .. 4) {
        immutable double a = alpha(amts[k], normals[k]);
        writefln("[light rig (iv)] amount %.1f %s: read %d, α %.2f β %.2f γ %.2f", amts[k],
                 k % 2 ? "key" : "ambient", r[k], a, beta(amts[k], normals[k]), gamma(amts[k], normals[k]));
        assert(abs(r[k] - a) <= 2, format("(iv) amount %.1f, %s normal: reads %d, α predicts %.2f "
            ~ "(β %.2f, γ %.2f)", amts[k], k % 2 ? "key-facing" : "ambient-only", r[k], a,
            beta(amts[k], normals[k]), gamma(amts[k], normals[k])));
    }
}

// ---------------------------------------------------------------------------
// (v) the specular term: Blinn from the material (amount 0.3, glossiness 0.3 =
// roughness 0.7 -> exponent 49.64 from the captured table), the viewer at
// infinity. Three quads: specular 0 vs 0.3 at a normal 10° off the key's half
// vector (the off-peak value separates the table exponent from 32 and 128),
// and a second point of the specular quad far from the first — with the viewer
// at infinity a flat quad's specular is uniform; a local viewer would vary it.
// ---------------------------------------------------------------------------
unittest {
    if (!cellOn("v")) return;
    setCamera(0.35, 0.25, 8.0);
    auto vp = viewportFromCameraMatrices();
    immutable D3 h1 = nrm(add3(kKey, [0, 0, 1]));
    // Tilt H1 by 10° about the eye x axis.
    immutable double t = 10 * PI / 180;
    immutable D3 n = nrm([h1[0], h1[1] * cos(t) - h1[2] * sin(t), h1[1] * sin(t) + h1[2] * cos(t)]);
    immutable double p = specPowerAt(0.7);
    immutable double pred0 = level(0.6, 0.8, 0.0, p, n), predS = level(0.6, 0.8, 0.3, p, n);
    // Floors: the specular adds ≥ 6 levels, does not clamp, and the table
    // exponent is ≥ 6 levels from the old 32 and the clamp 128.
    assert(predS - pred0 >= 6 && predS < 250, format("(v) floor: spec %.2f over %.2f", predS, pred0));
    assert(abs(predS - level(0.6, 0.8, 0.3, 32, n)) >= 6 && abs(predS - level(0.6, 0.8, 0.3, 128, n)) >= 6,
        format("(v) floor: the exponent cannot be told apart (%.2f / 32: %.2f / 128: %.2f)", predS,
               level(0.6, 0.8, 0.3, 32, n), level(0.6, 0.8, 0.3, 128, n)));
    immutable D3[] centresEye = [[-1.4, 0, 0], [1.2, 0, 0]];
    D3[] v; uint[][] f; D3[] cw;
    foreach (k; 0 .. 2) {
        immutable D3 c = add3(kC, toWorld(vp, centresEye[k]));
        cw ~= c;
        quadAt(c, nrm(toWorld(vp, n)), k == 0 ? 0.5 : 1.1, v, f);
    }
    loadMesh(v, f, [Surf(0.6, 0.8, 0.0, 0.3), Surf(0.6, 0.8, 0.3, 0.3)], [0u, 1]);
    restoreCamera(vp, 0.35, 0.25, 8.0);
    // The specular quad: its centre and a point 0.9 along its edge direction.
    immutable D3 far = add3(cw[1], toWorld(vp, [0.0, 0.9, 0.0]));
    immutable int[2][] pts = [cellPx(vp, cw[0]), cellPx(vp, cw[1]), cellPx(vp, far)];
    // Local-viewer counterfactual: the two specular points differ by ≥ 6.
    {
        immutable D3 eyeE = [0, 0, 0];   // the eye at the eye-space origin
        double localSpec(D3 pW) {
            immutable D3 pE = toEye(vp, add3(pW, [-vp.eye.x, -vp.eye.y, -vp.eye.z]));
            immutable D3 V = nrm([eyeE[0] - pE[0], eyeE[1] - pE[1], eyeE[2] - pE[2]]);
            immutable D3 H = nrm(add3(kKey, V));
            return 255.0 * 0.3 * kKeyI * pow(dot3(n, H), p);
        }
        assert(abs(localSpec(cw[1]) - localSpec(far)) >= 6,
            format("(v) floor: a local viewer would move the spec only %.2f across the quad",
                   abs(localSpec(cw[1]) - localSpec(far))));
    }
    const r = probeR(pts.dup);
    writefln("[light rig (v)] spec 0: %d (pred %.2f); spec 0.3: %d / %d (pred %.2f; exp 32 %.2f, 128 %.2f)",
             r[0], pred0, r[1], r[2], predS, level(0.6, 0.8, 0.3, 32, n), level(0.6, 0.8, 0.3, 128, n));
    assert(abs(r[0] - pred0) <= 2, format("(v) the specular-0 quad reads %d, predicted %.2f", r[0], pred0));
    assert(abs(r[1] - predS) <= 2, format("(v) the specular quad reads %d, predicted %.2f with the "
        ~ "table exponent %.2f (32 gives %.2f, 128 gives %.2f)", r[1], predS, p,
        level(0.6, 0.8, 0.3, 32, n), level(0.6, 0.8, 0.3, 128, n)));
    assert(abs(r[2] - predS) <= 2, format("(v) the specular quad's far point reads %d, predicted %.2f "
        ~ "— the viewer is at infinity, so a flat quad's specular is uniform", r[2], predS));
}
