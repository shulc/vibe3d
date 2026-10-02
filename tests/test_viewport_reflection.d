// The Reflection display style (viewport shading S4b, task 9250). Env arm:
// `out = litTerm(Kd, N) · env(envUv(R))`, R = reflect(P/|P|, N) in EYE space
// (the environment is glued to the camera — captured), envUv =
// (0.5 + atan2(R.x, R.z)/2π, acos(R.y)/π). MatCap arm: `out = diffuse(uv)·base
// + specular(uv)`, uv = (0.5 + 0.5 N.x, 0.5 − 0.5 N.y) from the eye normal.
//
// Every prediction is computed here: the eye-space N and R from a ray-sphere
// intersection through the LIVE camera matrices, the lit term as the SAME
// pixel read in the Shaded style in the same run, the image values from
// `/api/viewport/env-sample` (the CPU copy of the decoded image the GL upload
// used, bilinear at the same uv). Rig: a smooth 64x32 sphere of radius 1 at
// the focus, one surface (base 0.8, diffuse 1, no specular).
//
// Cells: (a) roll 90 / pitch 80 / heading +90 about the sphere leave the image
// unchanged, and a WORLD-space env predicts that they would not; (b) five
// probes read shaded × env(R) — the centre, where R = (0,0,+1) points back at
// the viewer, and four ≈ 45° off the view axis — and the opposite seam
// convention predicts otherwise; (c) MatCap `basic_grey` at five probes, and uv
// from R instead of N predicts otherwise; (d) an unknown source name is
// refused and changes nothing; (e) a two-sided surface's back side reflects
// with the flipped normal in both arms, a single-sided one is culled; (f) the
// hover override in both arms. `VIBE3D_CELL=<id>` runs one cell.

import http_client : getJson, postJson, frameFence, quiesce;
import http_command_helpers : commandBody;
import drag_helpers;

import std.format : format;
import std.json : JSONType, JSONValue;
import std.math : abs, sqrt, PI, cos, sin;
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

alias D3 = double[3];
D3 nrm(D3 v) { immutable l = sqrt(v[0]^^2 + v[1]^^2 + v[2]^^2); return [v[0]/l, v[1]/l, v[2]/l]; }
double dot3(D3 a, D3 b) { return a[0]*b[0] + a[1]*b[1] + a[2]*b[2]; }
D3 add3(D3 a, D3 b) { return [a[0]+b[0], a[1]+b[1], a[2]+b[2]]; }

double jnum(JSONValue v) {
    return v.type == JSONType.integer ? cast(double) v.integer
         : v.type == JSONType.uinteger ? cast(double) v.uinteger : v.floating;
}

double maxGap(double[3] a, double[3] b) {
    double g = 0;
    foreach (c; 0 .. 3) if (abs(a[c] - b[c]) > g) g = abs(a[c] - b[c]);
    return g;
}

// ---------------------------------------------------------------------------
// Live camera, probes, the sphere rig (the light-rig suite's).
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
enum double kBase = 0.8;

void setCamera(double az, double el, double dist, double roll = 0) {
    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"roll":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        az, el, dist, roll, kC[0], kC[1], kC[2]));
    frameFence(null, 2);
}

int[2] cellPx(const ref Viewport vp, D3 w) {
    float px, py;
    assert(projectToWindow(Vec3(cast(float)w[0], cast(float)w[1], cast(float)w[2]), vp, px, py),
        format("rig: %s is behind the camera", w));
    return [cast(int)(px + 0.5f) - vp.x, cast(int)(py + 0.5f) - vp.y];
}

int[3][] probeRGB(int[2][] pts) {
    int[3][] r;
    for (size_t s = 0; s < pts.length; s += 32) {
        string q;
        immutable e = s + 32 < pts.length ? s + 32 : pts.length;
        foreach (i, p; pts[s .. e]) q ~= format("%s%d,%d", i ? ";" : "", p[0], p[1]);
        auto j = getJson(format("/api/viewport/probe?cell=0&points=%s", q));
        assert(j["renders"].type == JSONType.true_, "probe: cell 0 must be rendering");
        foreach (pt; j["points"].array) {
            assert(("error" in pt) is null, "probe point refused: " ~ pt.toString);
            r ~= [cast(int)pt["r"].integer, cast(int)pt["g"].integer, cast(int)pt["b"].integer];
        }
    }
    return r;
}

/// The eye-space unit normal N and reflection R at the sphere point under
/// cell pixel `p` (the pixel centre's ray, as the rasteriser samples it).
bool hit(const ref Viewport vp, int[2] p, out D3 nEye, out D3 rEye) {
    Vec3 org, dir;
    pixelRay(p[0] + vp.x + 0.5f, p[1] + vp.y + 0.5f, vp, org, dir);
    immutable D3 o = [org.x - kC[0], org.y - kC[1], org.z - kC[2]], d = [dir.x, dir.y, dir.z];
    immutable double b = dot3(o, d), cc = dot3(o, o) - 1;
    immutable double disc = b * b - cc;
    if (disc < 0) return false;
    immutable double t = -b - sqrt(disc);
    immutable D3 n = nrm([o[0] + t*d[0], o[1] + t*d[1], o[2] + t*d[2]]);
    immutable double dn = dot3(d, n);
    immutable D3 r = [d[0] - 2*dn*n[0], d[1] - 2*dn*n[1], d[2] - 2*dn*n[2]];
    nEye = nrm(toEye(vp, n));
    rEye = nrm(toEye(vp, r));
    return true;
}

/// `/api/viewport/env-sample` for an environment at direction `dir`.
double[3] envAt(string name, D3 dir) {
    auto j = getJson(format("/api/viewport/env-sample?source=env:%s&dir=%.9f,%.9f,%.9f",
                            name, dir[0], dir[1], dir[2]));
    assert("rgb" in j, "env-sample failed: " ~ j.toString);
    return [jnum(j["rgb"][0]), jnum(j["rgb"][1]), jnum(j["rgb"][2])];
}

/// The same for a MatCap at normal `n`: [diffuse, specular].
double[3][2] matcapAt(string name, D3 n) {
    auto j = getJson(format("/api/viewport/env-sample?source=matcap:%s&n=%.9f,%.9f,%.9f",
                            name, n[0], n[1], n[2]));
    assert("diffuse" in j, "env-sample failed: " ~ j.toString);
    double[3][2] o;
    foreach (c; 0 .. 3) { o[0][c] = jnum(j["diffuse"][c]); o[1][c] = jnum(j["specular"][c]); }
    return o;
}

/// 0..255 of the env arm: the Shaded pixel (the lit term) times the env.
double[3] envPred(int[3] shaded, double[3] env) {
    double[3] o;
    foreach (c; 0 .. 3) {
        double v = shaded[c] / 255.0 * env[c];
        o[c] = 255.0 * (v > 1 ? 1 : v);
    }
    return o;
}

private int g_rig = 0;

/// A UV sphere of radius 1 at `kC`, poles on Y, wound outward, one surface.
void loadSphere() {
    enum int segs = 64, rings = 32;
    D3[] v; uint[][] f;
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
    g_v = v; g_f = f;
    loadMesh(v, f, false);
}

/// The sphere's vertices and faces as last loaded (the hover cell's centroid).
private D3[] g_v;
private uint[][] g_f;

/// Load `v`/`f` as one layer of one surface (base `kBase`, no specular).
void loadMesh(D3[] v, uint[][] f, bool twoSided) {
    import std.file : write, remove, exists, tempDir;
    import std.path : buildPath;
    import std.process : thisProcessID;
    string vs, fs, ms;
    foreach (i, x; v) vs ~= format("%s[%.9g,%.9g,%.9g]", i ? "," : "", x[0], x[1], x[2]);
    foreach (i, face; f) {
        fs ~= i ? ",[" : "[";
        foreach (j, x; face) fs ~= format("%s%d", j ? "," : "", x);
        fs ~= "]";
        ms ~= i ? ",0" : "0";
    }
    immutable surf = format(`{"name":"R","baseColor":[%.9g,%.9g,%.9g],"diffuse":1,`
        ~ `"specular":0,"glossiness":0.4,"opacity":1,"twoSided":%s}`, kBase, kBase, kBase,
        twoSided ? "true" : "false");
    immutable path = buildPath(tempDir(), format("vibe3d-reflection-%d-%d.v3d", thisProcessID(), g_rig++));
    write(path, `{"formatVersion":8,"primaryLayer":0,"focusedItem":0,"layers":[{"type":"mesh",`
        ~ `"selected":true,"channels":{"name":"Rig","visible":true},"mesh":{"vertices":[` ~ vs
        ~ `],"faces":[` ~ fs ~ `],"surfaces":[` ~ surf ~ `],"faceMaterial":[` ~ ms ~ `]}}]}`);
    scope(exit) if (exists(path)) remove(path);
    auto rr = postJson("/api/command", commandBody("scene.reset"));
    assert(rr["status"].str == "ok", "scene.reset failed: " ~ rr.toString);
    runCmd("file.load", format(`{"path":"%s"}`, path));
    auto m = getJson("/api/model");
    assert(m["faces"].array.length == f.length, "rig: the mesh did not load");
    auto s0 = m["surfaces"].array[0];
    assert(("twoSided" in s0) !is null, "rig: /api/model must report the surface's twoSided flag");
    immutable bool ts = s0["twoSided"].type == JSONType.true_;
    assert(ts == twoSided, format("rig: the surface must load with twoSided %s", twoSided));
    cmd("viewport.wireOverlay none");
    cmd("select.typeFrom polygon");
    frameFence(null, 2);
}

void style(string s) {
    cmd(commandBody("viewport.displayStyle", format(`{"value":"%s"}`, s)));
    frameFence(null, 2);
}

void source(string id) {
    cmd(commandBody("viewport.reflectionSource", format(`{"value":"%s"}`, id)));
    auto plan = getJson("/api/viewport/display")["cells"].array[0]["plan"]["active"];
    assert(plan["shading"].str == "Reflection" && plan["reflection"].str == id,
        "rig premise: cell 0's active plan must be the Reflection arm on " ~ id ~ ": "
        ~ plan.toString);
    frameFence(null, 2);
}

/// Five probes: the disc centre and four points at 0.38 of the disc radius
/// in the screen directions `deg` (counter-clockwise from screen right): the
/// normal ≈ 22° off the view axis, so R ≈ 45° off it.
int[2][] fiveProbes(const ref Viewport vp, double dist, double[4] deg) {
    immutable int[2] c = cellPx(vp, kC);
    immutable double rPx = 1.0 / dist * vp.proj[5] * vp.height / 2;
    int[2][] pts = [c];
    foreach (d; deg) {
        immutable double a = d * PI / 180;
        pts ~= [c[0] + cast(int)(0.38 * rPx * cos(a)), c[1] - cast(int)(0.38 * rPx * sin(a))];
    }
    return pts;
}

// ---------------------------------------------------------------------------
// (a) the env is VIEW-space: roll 90°, pitch 80° and heading +90° about the
// sphere leave every inside-disc probe at its base value (±2). Floor: an env
// looked up with the WORLD-space R moves ≥ 25 % of them by > 8 levels.
// ---------------------------------------------------------------------------
unittest {
    if (!cellOn("a")) return;
    loadSphere();
    scope(exit) postJson("/api/command", commandBody("viewport.displayStyle", `{"value":"shaded"}`));
    enum double dist = 4.0, el0 = 0.3;
    setCamera(0, el0, dist);
    auto vp0 = viewportFromCameraMatrices();
    immutable int[2] c0 = cellPx(vp0, kC);
    immutable double rPx = 1.0 / dist * vp0.proj[5] * vp0.height / 2;
    int[2][] pts;
    foreach (iy; -5 .. 5) foreach (ix; -5 .. 5) {
        immutable double dx = (ix + 0.5) * 0.16 * rPx, dy = (iy + 0.5) * 0.16 * rPx;
        if (dx * dx + dy * dy > (0.8 * rPx) ^^ 2) continue;
        pts ~= [c0[0] + cast(int) dx, c0[1] + cast(int) dy];
    }
    // Floor on the classified-inside count [E4].
    assert(pts.length >= 40, format("(a) floor: only %d probe points inside the disc", pts.length));
    assert(rPx >= 60, format("(a) rig: the sphere is only %.0f px in radius", rPx));
    style("shaded");
    const shaded = probeRGB(pts);
    style("reflection");
    source("env:studio_small_09");
    const base = probeRGB(pts);
    D3[] rWorld0;
    foreach (p; pts) {
        D3 n, r;
        assert(hit(vp0, p, n, r), format("(a) rig: the base ray at %s misses the sphere", p));
        rWorld0 ~= toWorld(vp0, r);
    }
    immutable double[3][] cams = [[0, el0, PI / 2], [0, 80 * PI / 180, 0], [PI / 2, el0, 0]];
    immutable string[] names = ["roll 90", "pitch 80", "heading +90"];
    foreach (ci, cam; cams) {
        setCamera(cam[0], cam[1], dist, cam[2]);
        auto vp = viewportFromCameraMatrices();
        // Counterfactual: the env looked up with the world-space R.
        size_t moved, both;
        foreach (k, p; pts) {
            D3 n, r;
            if (!hit(vp, p, n, r)) continue;
            ++both;
            immutable double[3] w0 = envPred(shaded[k], envAt("studio_small_09", toEye(vp0, rWorld0[k])));
            immutable double[3] w1 = envPred(shaded[k], envAt("studio_small_09", toEye(vp0, toWorld(vp, r))));
            if (maxGap(w0, w1) > 8) ++moved;
        }
        assert(both == pts.length, format("(a) %s: %d of %d probe rays miss the sphere",
                                          names[ci], pts.length - both, pts.length));
        assert(moved * 4 >= pts.length, format("(a) %s discrimination floor: a world-space env "
            ~ "moves only %d of %d points by > 8 levels", names[ci], moved, pts.length));
        const got = probeRGB(pts);
        size_t worst; int worstD;
        foreach (k; 0 .. pts.length) foreach (c; 0 .. 3)
            if (abs(got[k][c] - base[k][c]) > worstD) { worstD = abs(got[k][c] - base[k][c]); worst = k; }
        writefln("[reflection (a)] %s: max |delta| %d over %d points (a world-space env would move %d)",
                 names[ci], worstD, pts.length, moved);
        assert(worstD <= 2, format("(a) %s: point %s reads %s, base %s — the environment must "
            ~ "turn with the camera (view-space env)", names[ci], pts[worst], got[worst], base[worst]));
    }
}

// ---------------------------------------------------------------------------
// (b) the mapping: five probes read shaded × env(envUv(R)) ±3. Floor: the
// opposite seam convention u = 0.5 + atan2(R.x, −R.z)/2π (= the env at
// (R.x, R.y, −R.z)) predicts ≥ 10 levels apart for ≥ 3 of the 5.
// ---------------------------------------------------------------------------
unittest {
    if (!cellOn("b")) return;
    loadSphere();
    scope(exit) postJson("/api/command", commandBody("viewport.displayStyle", `{"value":"shaded"}`));
    enum double dist = 4.0;
    setCamera(0.35, 0.3, dist);
    auto vp = viewportFromCameraMatrices();
    // Directions where the studio image is neither saturated nor flat, chosen
    // from the image (a front/back-symmetric spot cannot see the seam).
    auto pts = fiveProbes(vp, dist, [135.0, 180.0, 225.0, 270.0]);
    style("shaded");
    const shaded = probeRGB(pts);
    style("reflection");
    source("env:studio_small_09");
    const got = probeRGB(pts);
    double[3][] pred;
    size_t apart;
    foreach (k, p; pts) {
        D3 n, r;
        assert(hit(vp, p, n, r), format("(b) rig: probe %s misses the sphere", p));
        if (k == 0)
            assert(r[2] > 0.999, format("(b) premise: the centre's R %s must point back at the viewer", r));
        pred ~= envPred(shaded[k], envAt("studio_small_09", r));
        immutable double[3] flip = envPred(shaded[k], envAt("studio_small_09", [r[0], r[1], -r[2]]));
        if (maxGap(pred[k], flip) >= 10) ++apart;
        writefln("[reflection (b)] probe %d %s: R (%.3f,%.3f,%.3f) shaded %s read %s predicted "
            ~ "(%.2f,%.2f,%.2f), flipped seam (%.2f,%.2f,%.2f)", k, p, r[0], r[1], r[2], shaded[k],
            got[k], pred[k][0], pred[k][1], pred[k][2], flip[0], flip[1], flip[2]);
    }
    assert(apart >= 3, format("(b) discrimination floor: the opposite seam convention is ≥ 10 "
        ~ "levels apart at only %d of 5 probes", apart));
    foreach (k; 0 .. 5) foreach (c; 0 .. 3)
        assert(abs(got[k][c] - pred[k][c]) <= 3, format("(b) probe %d %s reads %s; shaded %s × "
            ~ "env(envUv(R)) predicts (%.2f,%.2f,%.2f) ±3", k, pts[k], got[k], shaded[k],
            pred[k][0], pred[k][1], pred[k][2]));
}

// ---------------------------------------------------------------------------
// (c) MatCap `basic_grey`: diffuse(uv)·base + specular(uv), uv from the EYE
// NORMAL, no light term. Floor: uv from R instead predicts ≥ 10 levels apart
// for ≥ 3 of the 5 (the four off-centre probes have N.y ≠ 0, so a missing
// t-flip moves them too).
// ---------------------------------------------------------------------------
unittest {
    if (!cellOn("c")) return;
    loadSphere();
    scope(exit) postJson("/api/command", commandBody("viewport.displayStyle", `{"value":"shaded"}`));
    enum double dist = 4.0;
    setCamera(0.35, 0.3, dist);
    auto vp = viewportFromCameraMatrices();
    auto pts = fiveProbes(vp, dist, [45.0, 135.0, 225.0, 315.0]);
    style("reflection");
    source("matcap:basic_grey");
    const got = probeRGB(pts);
    double[3] mc(double[3][2] m) {
        double[3] o;
        foreach (c; 0 .. 3) { immutable v = m[0][c] * kBase + m[1][c]; o[c] = 255.0 * (v > 1 ? 1 : v); }
        return o;
    }
    size_t apart;
    double[3][] pred;
    foreach (k, p; pts) {
        D3 n, r;
        assert(hit(vp, p, n, r), format("(c) rig: probe %s misses the sphere", p));
        if (k > 0) assert(abs(n[1]) > 0.1, format("(c) premise: probe %d's N.y must be off zero: %s", k, n));
        pred ~= mc(matcapAt("basic_grey", n));
        immutable double[3] fromR = mc(matcapAt("basic_grey", r));
        if (maxGap(pred[k], fromR) >= 10) ++apart;
        writefln("[reflection (c)] probe %d %s: N (%.3f,%.3f,%.3f) read %s predicted (%.2f,%.2f,%.2f), "
            ~ "uv from R (%.2f,%.2f,%.2f)", k, p, n[0], n[1], n[2], got[k], pred[k][0], pred[k][1],
            pred[k][2], fromR[0], fromR[1], fromR[2]);
    }
    assert(apart >= 3, format("(c) discrimination floor: uv from R is ≥ 10 levels apart at only "
        ~ "%d of 5 probes", apart));
    foreach (k; 0 .. 5) foreach (c; 0 .. 3)
        assert(abs(got[k][c] - pred[k][c]) <= 3, format("(c) probe %d %s reads %s; diffuse·base + "
            ~ "specular at matcapUv(N) predicts (%.2f,%.2f,%.2f) ±3", k, pts[k], got[k],
            pred[k][0], pred[k][1], pred[k][2]));
}

// ---------------------------------------------------------------------------
// (d) an unknown source name is REFUSED: status:error (the witness: viewport
// commands never record history, so the unchanged undo depth is a census,
// not a refusal witness) and the cell's source unchanged. Positive control
// first: a bundled name is accepted and lands in the state. The CPU sampler
// refuses a zero or non-finite vector with 400, a valid one answers.
// ---------------------------------------------------------------------------
unittest {
    if (!cellOn("d")) return;
    string stateSource() {
        return getJson("/api/viewport/display")["cells"].array[0]["state"]["reflection"].str;
    }
    cmd(commandBody("viewport.reflectionSource", `{"value":"matcap:clay_studio"}`));
    scope(exit) cmd(commandBody("viewport.reflectionSource", `{"value":"env:studio_small_09"}`));
    assert(stateSource() == "matcap:clay_studio",
        "(d) control: an accepted source must land in the cell state, got " ~ stateSource());
    immutable size_t depth = getJson("/api/history")["undo"].array.length;
    auto r = postJson("/api/command", commandBody("viewport.reflectionSource", `{"value":"env:nope"}`));
    writefln("[reflection (d)] env:nope -> %s", r.toString);
    assert(r["status"].str == "error", "(d) an unknown source must be refused: " ~ r.toString);
    assert(stateSource() == "matcap:clay_studio",
        "(d) a refused source must leave the cell's source unchanged, got " ~ stateSource());
    assert(getJson("/api/history")["undo"].array.length == depth,
        "(d) a refused source must record no history entry");
    string sample(string q) {
        try {
            auto j = getJson("/api/viewport/env-sample?" ~ q);
            return ("rgb" in j) !is null || ("diffuse" in j) !is null ? "ok" : j.toString;
        } catch (Exception e) {
            import std.algorithm.searching : canFind;
            return e.msg.canFind("400") ? "400" : e.msg;
        }
    }
    assert(sample("source=env:studio_small_09&dir=0,0,1") == "ok",
        "(d) control: a unit dir must be answered");
    foreach (q; ["source=env:studio_small_09&dir=0,0,0", "source=env:studio_small_09&dir=nan,0,1",
                 "source=matcap:basic_grey&n=inf,0,0"])
        assert(sample(q) == "400", "(d) env-sample must refuse " ~ q ~ " with 400, got " ~ sample(q));
}

/// 0..255 of the env arm for a lit term given in 0..1 (the floors' counterfactuals).
double[3] envPredLit(double[3] lit, double[3] env) {
    double[3] o;
    foreach (c; 0 .. 3) { immutable v = lit[c] * env[c]; o[c] = 255.0 * (v > 1 ? 1 : v); }
    return o;
}

/// 0..255 of the MatCap arm at base `b`: diffuse·b + specular.
double[3] matcapPred(double[3][2] m, double[3] b) {
    double[3] o;
    foreach (c; 0 .. 3) { immutable v = m[0][c] * b[c] + m[1][c]; o[c] = 255.0 * (v > 1 ? 1 : v); }
    return o;
}

/// Set the camera and assert it equals `vp` (a load may move it).
void restoreCamera(const ref Viewport vp, double az, double el, double dist) {
    setCamera(az, el, dist);
    auto now = viewportFromCameraMatrices();
    foreach (i; 0 .. 16)
        assert(abs(now.view[i] - vp.view[i]) < 1e-5, "rig: the camera did not come back after the load");
}

// ---------------------------------------------------------------------------
// (e) the BACK side. A flat quad (world normal +Z, base kBase) seen from
// behind. Two-sided: the back side shades with the FLIPPED normal (the lit
// arms' shadingNormal, model M6). Env: reads Shaded-back × env(R) ±3 — R is
// sign-symmetric in N, so the lit term is what a raw normal changes; floor: the
// lit term of the RAW normal predicts ≥ 10 levels apart at ≥ 3 of 5. MatCap:
// diffuse·base + specular at matcapUv(N_flipped) ±3; floor: matcapUv(N_raw)
// predicts ≥ 10 apart. Single-sided: Reflection culls by surface like Shaded,
// so the probes read the Shaded (culled: background) value ±2; floors: Solid,
// which never culls, reads ≥ 10 from it at all 5 (the face covers them), and
// the two-sided env read is ≥ 10 from it at ≥ 3 (a drawn back face shows).
// ---------------------------------------------------------------------------
unittest {
    if (!cellOn("e")) return;
    scope(exit) postJson("/api/command", commandBody("viewport.displayStyle", `{"value":"shaded"}`));
    D3[] qv = [add3(kC, [-1.5, -1.5, 0.0]), add3(kC, [1.5, -1.5, 0.0]),
               add3(kC, [1.5, 1.5, 0.0]), add3(kC, [-1.5, 1.5, 0.0])];
    uint[][] qf = [[0u, 1u, 2u, 3u]];
    enum double dist = 4.0, el = 0.3;
    loadMesh(qv, qf, true);
    double az = 0.6;
    setCamera(az, el, dist);
    auto vp = viewportFromCameraMatrices();
    if (toEye(vp, [0.0, 0.0, 1.0])[2] > 0) {
        az += PI;
        setCamera(az, el, dist);
        vp = viewportFromCameraMatrices();
    }
    immutable D3 nRaw = nrm(toEye(vp, [0.0, 0.0, 1.0]));
    immutable D3 nFlip = [-nRaw[0], -nRaw[1], -nRaw[2]];
    assert(nRaw[2] < -0.3, format("(e) premise: the camera must see the quad's back, raw N %s", nRaw));
    assert(abs(nRaw[0]) + abs(nRaw[1]) > 0.3,
        format("(e) premise: the eye normal must lean off the view axis, %s", nRaw));
    auto pts = fiveProbes(vp, dist, [45.0, 135.0, 225.0, 315.0]);
    D3[] rs;
    foreach (p; pts) {
        Vec3 org, dir;
        pixelRay(p[0] + vp.x + 0.5f, p[1] + vp.y + 0.5f, vp, org, dir);
        immutable double t = (kC[2] - org.z) / dir.z;
        immutable D3 hitW = [org.x + t * dir.x - kC[0], org.y + t * dir.y - kC[1], 0.0];
        assert(t > 0 && abs(hitW[0]) < 1.4 && abs(hitW[1]) < 1.4,
            format("(e) rig: probe %s misses the quad (t %.3f, at %s)", p, t, hitW));
        immutable D3 d = [dir.x, dir.y, dir.z];
        immutable double dz = d[2];
        rs ~= nrm(toEye(vp, [d[0], d[1], d[2] - 2 * dz]));
    }
    style("shaded");
    const shadedTwo = probeRGB(pts);
    style("reflection");
    source("env:studio_small_09");
    const envTwo = probeRGB(pts);
    source("matcap:basic_grey");
    const mcTwo = probeRGB(pts);
    // The raw normal's lit term: light_rig's kKeyLightEye / kFillLightEye,
    // intensities 0.7 / 0.3, ambient 0.15 (copied; the suite cannot import it).
    // No specular in the rig.
    enum double kKeyIntensity = 0.7, kFillIntensity = 0.3, kLightAmbient = 0.15;
    immutable D3 kKey = [-0.654509, 0.587785, 0.475528], kFill = [1.0, 0.0, 0.0];
    immutable double nk = dot3(nRaw, kKey), nf = dot3(nRaw, kFill);
    immutable double litRawS = kBase * (kLightAmbient + kKeyIntensity * (nk > 0 ? nk : 0)
                                                      + kFillIntensity * (nf > 0 ? nf : 0));
    immutable double[3] litRaw = [litRawS, litRawS, litRawS];
    size_t envApart;
    double[3][] envPredTwo;
    foreach (k; 0 .. 5) {
        immutable double[3] e = envAt("studio_small_09", rs[k]);
        envPredTwo ~= envPred(shadedTwo[k], e);
        if (maxGap(envPredTwo[k], envPredLit(litRaw, e)) >= 10) ++envApart;
        writefln("[reflection (e)] probe %d %s: shaded-back %s env read %s predicted (%.2f,%.2f,%.2f), "
            ~ "raw-normal lit %.3f", k, pts[k], shadedTwo[k], envTwo[k], envPredTwo[k][0],
            envPredTwo[k][1], envPredTwo[k][2], litRawS);
    }
    assert(envApart >= 3, format("(e) env discrimination floor: the raw normal's lit term is ≥ 10 "
        ~ "levels apart at only %d of 5 probes", envApart));
    immutable double[3] kB = [kBase, kBase, kBase];
    immutable double[3] mcFlip = matcapPred(matcapAt("basic_grey", nFlip), kB);
    immutable double[3] mcRaw = matcapPred(matcapAt("basic_grey", nRaw), kB);
    writefln("[reflection (e)] matcap: read %s predicted (%.2f,%.2f,%.2f), raw normal (%.2f,%.2f,%.2f)",
        mcTwo[0], mcFlip[0], mcFlip[1], mcFlip[2], mcRaw[0], mcRaw[1], mcRaw[2]);
    assert(maxGap(mcFlip, mcRaw) >= 10, format("(e) matcap discrimination floor: uv(N_raw) %s vs "
        ~ "uv(N_flipped) %s", mcRaw, mcFlip));
    foreach (k; 0 .. 5) foreach (c; 0 .. 3) {
        assert(abs(envTwo[k][c] - envPredTwo[k][c]) <= 3, format("(e) env back side, probe %d %s "
            ~ "reads %s; Shaded-back %s × env(R) predicts %s ±3 (the back side must reflect with the "
            ~ "flipped normal)", k, pts[k], envTwo[k], shadedTwo[k], envPredTwo[k]));
        assert(abs(mcTwo[k][c] - mcFlip[c]) <= 3, format("(e) matcap back side, probe %d %s reads "
            ~ "%s; matcapUv(N_flipped) predicts %s ±3 (raw normal: %s)", k, pts[k], mcTwo[k], mcFlip,
            mcRaw));
    }
    // Single-sided: culled under Reflection as under Shaded.
    loadMesh(qv, qf, false);
    restoreCamera(vp, az, el, dist);
    style("solid");
    const solidOne = probeRGB(pts);
    style("shaded");
    const bg = probeRGB(pts);
    style("reflection");
    source("env:studio_small_09");
    const reflOne = probeRGB(pts);
    size_t drawnApart;
    foreach (k; 0 .. 5) {
        assert(maxGap([solidOne[k][0], solidOne[k][1], solidOne[k][2]], [bg[k][0], bg[k][1], bg[k][2]])
            >= 10, format("(e) cull floor: probe %d — Solid %s must read the face, ≥ 10 from the "
            ~ "culled Shaded %s", k, solidOne[k], bg[k]));
        if (maxGap([envTwo[k][0], envTwo[k][1], envTwo[k][2]], [bg[k][0], bg[k][1], bg[k][2]]) >= 10)
            ++drawnApart;
    }
    assert(drawnApart >= 3, format("(e) cull floor: a drawn back face reads ≥ 10 from the background "
        ~ "at only %d of 5 probes", drawnApart));
    foreach (k; 0 .. 5) foreach (c; 0 .. 3)
        assert(abs(reflOne[k][c] - bg[k][c]) <= 2, format("(e) single-sided back side, probe %d %s: "
            ~ "Reflection reads %s, culled Shaded %s — Reflection must cull by surface", k, pts[k],
            reflOne[k], bg[k]));
}

// ---------------------------------------------------------------------------
// (f) hover in both arms: the hover override replaces the base (u_color =
// viewport_scheme.kFaceHoverFill = (0.5, 0.71, 0.79), mix 1). Env: the hovered
// face reads Shaded-hovered × env(R), the unhovered one Shaded × env(R); MatCap:
// diffuse·hover + specular vs diffuse·base + specular. Floors: at the hovered
// pixel the hovered and unhovered predictions are ≥ 6 levels apart per arm.
// ---------------------------------------------------------------------------
unittest {
    if (!cellOn("f")) return;
    loadSphere();
    scope(exit) postJson("/api/command", commandBody("viewport.displayStyle", `{"value":"shaded"}`));
    enum double az = 0.35, el = 0.3, dist = 4.0;
    setCamera(az, el, dist);
    auto vp = viewportFromCameraMatrices();
    // Pick the two brightest UNSATURATED env spots (max channel ≤ 1.6, so
    // Shaded ≈ 0.5 × env stays below 1) on three rings, ≥ 40 px apart: a dark
    // spot cannot tell the hover colour from the base.
    immutable int[2] cc = cellPx(vp, kC);
    immutable double rPx = 1.0 / dist * vp.proj[5] * vp.height / 2;
    int[2][] cand;
    double[] score;
    foreach (ring; [0.2, 0.38, 0.55]) foreach (i; 0 .. 12) {
        immutable double a = i * PI / 6;
        immutable int[2] p = [cc[0] + cast(int)(ring * rPx * cos(a)), cc[1] - cast(int)(ring * rPx * sin(a))];
        D3 n, r;
        if (!hit(vp, p, n, r)) continue;
        immutable double[3] e = envAt("studio_small_09", r);
        immutable double mx = e[0] > e[1] ? (e[0] > e[2] ? e[0] : e[2]) : (e[1] > e[2] ? e[1] : e[2]);
        immutable double mn = e[0] < e[1] ? (e[0] < e[2] ? e[0] : e[2]) : (e[1] < e[2] ? e[1] : e[2]);
        if (mx > 1.6) continue;
        cand ~= p; score ~= mn;
    }
    assert(cand.length >= 2, format("(f) rig: only %d unsaturated candidate points", cand.length));
    size_t b0 = 0;
    foreach (i; 0 .. cand.length) if (score[i] > score[b0]) b0 = i;
    size_t b1 = size_t.max;
    foreach (i; 0 .. cand.length) {
        immutable dx = cand[i][0] - cand[b0][0], dy = cand[i][1] - cand[b0][1];
        if (dx * dx + dy * dy < 1600) continue;
        if (b1 == size_t.max || score[i] > score[b1]) b1 = i;
    }
    assert(b1 != size_t.max, "(f) rig: no second candidate 40 px away");
    int[2][] five = [cc, cand[b0], cc, cand[b1]];
    // The face under five[1] (nearest centroid to its hit point), probed at its centroid.
    D3 n1, r1;
    assert(hit(vp, five[1], n1, r1), "(f) rig: probe 1 misses the sphere");
    immutable D3 h1 = add3(kC, toWorld(vp, n1));
    size_t hf = size_t.max;
    double best = double.max;
    D3 cen;
    foreach (i, face; g_f) {
        D3 c = [0, 0, 0];
        foreach (x; face) c = add3(c, g_v[x]);
        c = [c[0] / face.length, c[1] / face.length, c[2] / face.length];
        immutable double d2 = (c[0]-h1[0])^^2 + (c[1]-h1[1])^^2 + (c[2]-h1[2])^^2;
        if (d2 < best) { best = d2; hf = i; cen = c; }
    }
    immutable int[2] p0 = cellPx(vp, cen), p1 = five[3];
    D3 n0, r0, nn1, rr1;
    assert(hit(vp, p0, n0, r0) && hit(vp, p1, nn1, rr1), "(f) rig: a probe misses the sphere");
    style("shaded");
    const shadedUn = probeRGB([p0, p1]);
    auto cam = getJson("/api/camera");
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        cam["vpX"].integer, cam["vpY"].integer, cam["width"].integer, cam["height"].integer);
    foreach (i; 0 .. 5)
        log ~= format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}`
            ~ "\n", 50.0 + i * 20.0, p0[0] + vp.x, p0[1] + vp.y);
    playAndWait(log);
    quiesce();
    restoreCamera(vp, az, el, dist);
    void hovered(string when) {
        immutable h = getJson("/api/toolpipe/eval")["hover"]["face"].integer;
        assert(h == cast(long) hf, format("(f) rig %s: the pointer must hover face %d, hovers %d", when, hf, h));
    }
    hovered("Shaded");
    const shadedH = probeRGB([p0, p1]);
    style("reflection");
    source("env:studio_small_09");
    hovered("env");
    const envR = probeRGB([p0, p1]);
    source("matcap:basic_grey");
    hovered("matcap");
    const mcR = probeRGB([p0, p1]);
    immutable double[3] e0 = envAt("studio_small_09", r0), e1 = envAt("studio_small_09", rr1);
    immutable double[3] envHov = envPred(shadedH[0], e0), envUnAt0 = envPred(shadedUn[0], e0),
                        envUn1 = envPred(shadedUn[1], e1);
    immutable double[3] kHover = [0.5, 0.71, 0.79], kB = [kBase, kBase, kBase];
    immutable m0 = matcapAt("basic_grey", n0), m1 = matcapAt("basic_grey", nn1);
    immutable double[3] mcHov = matcapPred(m0, kHover), mcUnAt0 = matcapPred(m0, kB),
                        mcUn1 = matcapPred(m1, kB);
    writefln("[reflection (f)] face %d at %s: Shaded %s -> hovered %s; env read %s pred hovered "
        ~ "(%.2f,%.2f,%.2f) unhovered (%.2f,%.2f,%.2f); matcap read %s pred hovered (%.2f,%.2f,%.2f) "
        ~ "unhovered (%.2f,%.2f,%.2f)", hf, p0, shadedUn[0], shadedH[0], envR[0], envHov[0], envHov[1],
        envHov[2], envUnAt0[0], envUnAt0[1], envUnAt0[2], mcR[0], mcHov[0], mcHov[1], mcHov[2],
        mcUnAt0[0], mcUnAt0[1], mcUnAt0[2]);
    assert(maxGap(envHov, envUnAt0) >= 6, format("(f) env floor: hovered %s vs unhovered %s", envHov, envUnAt0));
    assert(maxGap(mcHov, mcUnAt0) >= 6, format("(f) matcap floor: hovered %s vs unhovered %s", mcHov, mcUnAt0));
    foreach (c; 0 .. 3) {
        assert(abs(envR[1][c] - envUn1[c]) <= 3, format("(f) env: the unhovered probe %s reads %s, "
            ~ "predicted %s", p1, envR[1], envUn1));
        assert(abs(mcR[1][c] - mcUn1[c]) <= 3, format("(f) matcap: the unhovered probe %s reads %s, "
            ~ "predicted %s", p1, mcR[1], mcUn1));
        assert(abs(envR[0][c] - envHov[c]) <= 3, format("(f) env: the hovered face reads %s; "
            ~ "Shaded-hovered × env predicts %s (unhovered: %s)", envR[0], envHov, envUnAt0));
        assert(abs(mcR[0][c] - mcHov[c]) <= 3, format("(f) matcap: the hovered face reads %s; "
            ~ "diffuse·hover + specular predicts %s (unhovered: %s)", mcR[0], mcHov, mcUnAt0));
    }
}
