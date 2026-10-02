// Per-surface smoothing and the default material (viewport shading S1e, model
// M3): each surface carries `smoothing` + `smoothingAngle`; the smooth stream's
// corner rule reads them per face, the surface of the LOWER slot deciding each
// pair for both faces; `viewport.smooth` ANDs with it (captured C8e); the
// default material is Kd 0.48 with a 0.04 Blinn highlight. Rigs are open hinge
// strips written to a `.v3d` (never a cube for smoothing); every pixel
// prediction is computed here from the lit program's light function.

import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import drag_helpers;

import core.thread : Thread;
import core.time : msecs;
import std.algorithm : max, min, canFind;
import std.conv : to;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : abs, sqrt, cos, sin, pow, round, PI;
import http_client : frameFence;
import std.stdio : writefln;

void main() {}

/// `VIBE3D_CELL=<id>` runs one cell (druntime stops a module at its first
/// failed assert, so a mutation that must redden two cells runs them apart).
bool cellOn(string id) {
    import std.process : environment;
    immutable e = environment.get("VIBE3D_CELL", "");
    return e.length == 0 || e == id;
}

JSONValue post(string script) { return postJson("/api/command", script); }

void cmd(string script) {
    auto r = post(script);
    assert(r["status"].str == "ok", "/api/command failed for " ~ script ~ ": " ~ r.toString);
}

void runCmd(string id, string paramsJson) {
    cmd(`{"id":"` ~ id ~ `","params":` ~ paramsJson ~ `}`);
}

string attrBody(int surface, string attr, double value) {
    return format(`{"id":"mesh.surfaceAttr","params":{"surface":%d,"attr":"%s","value":%.6f}}`,
                  surface, attr, value);
}

size_t undoDepth() { return getJson("/api/history")["undo"].array.length; }

double num(JSONValue v) {
    return v.type == JSONType.integer ? cast(double)v.integer
         : v.type == JSONType.uinteger ? cast(double)v.uinteger : v.floating;
}

/// Set an attribute of slot `s` only when it differs (the command refuses a no-op).
void setAttr(int s, string attr, double value) {
    auto surfs = getJson("/api/model")["surfaces"].array;
    if (s < surfs.length) {
        auto cur = surfs[s];
        if (attr == "smoothing" && (cur["smoothing"].type == JSONType.true_) == (value != 0)) return;
        if (attr == "smoothingAngle" && abs(num(cur["smoothingAngle"]) - value) < 1e-6) return;
    }
    cmd(attrBody(s, attr, value));
}

alias V3 = drag_helpers.Vec3;
V3 sub(V3 a, V3 b) { return V3(a.x - b.x, a.y - b.y, a.z - b.z); }
V3 add(V3 a, V3 b) { return V3(a.x + b.x, a.y + b.y, a.z + b.z); }
V3 scl(V3 a, double s) { return V3(cast(float)(a.x * s), cast(float)(a.y * s), cast(float)(a.z * s)); }
V3 crs(V3 a, V3 b) { return V3(a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x); }
double dt(V3 a, V3 b) { return cast(double)a.x*b.x + cast(double)a.y*b.y + cast(double)a.z*b.z; }
V3 unit(V3 a) { immutable double l = sqrt(dt(a, a)); return V3(a.x / l, a.y / l, a.z / l); }
V3 faceNormal(V3[] v, uint[] f) { return unit(crs(sub(v[f[1]], v[f[0]]), sub(v[f[2]], v[f[0]]))); }

// ---------------------------------------------------------------------------
// The rig file
// ---------------------------------------------------------------------------

struct Surf { bool on = true; double angle = 40; double[3] base = [0.6, 0.6, 0.6]; }

private int g_rig = 0;

/// Replace the scene with ONE mesh layer: `verts`, `faces`, optional face tags
/// and surface table (default-material colour channels, smoothing as given).
void loadRig(V3[] verts, uint[][] faces, uint[] mats = null, Surf[] surfs = null) {
    import std.file : write, remove, exists, mkdirRecurse;
    import std.path : buildPath;
    import std.process : thisProcessID, environment;
    string vs, fs, ms, ss;
    foreach (i, v; verts) vs ~= format("%s[%.9g,%.9g,%.9g]", i ? "," : "", v.x, v.y, v.z);
    foreach (i, f; faces) {
        fs ~= i ? ",[" : "[";
        foreach (j, x; f) fs ~= format("%s%d", j ? "," : "", x);
        fs ~= "]";
    }
    string extra;
    if (mats.length) {
        foreach (i, m; mats) ms ~= format("%s%d", i ? "," : "", m);
        extra ~= `,"faceMaterial":[` ~ ms ~ `]`;
    }
    if (surfs.length) {
        foreach (i, s; surfs)
            ss ~= format(`%s{"name":"S%d","baseColor":[%.6f,%.6f,%.6f],"diffuse":0.8,"specular":0.04,`
                       ~ `"glossiness":0.6,"opacity":1,"smoothing":%s,"smoothingAngle":%.6f}`,
                         i ? "," : "", i, s.base[0], s.base[1], s.base[2], s.on ? "true" : "false", s.angle);
        extra ~= `,"surfaces":[` ~ ss ~ `]`;
    }
    immutable dir = buildPath(environment.get("TMPDIR", "/var/tmp"), format("s1e-%d", thisProcessID()));
    mkdirRecurse(dir);
    immutable path = buildPath(dir, format("s1e_rig_%d.v3d", g_rig++));
    write(path, `{"formatVersion":8,"primaryLayer":0,"focusedItem":0,"layers":[{"type":"mesh",`
        ~ `"selected":true,"channels":{"name":"Rig","visible":true},"mesh":{"vertices":[` ~ vs
        ~ `],"faces":[` ~ fs ~ `]` ~ extra ~ `}}]}`);
    scope(exit) if (exists(path)) remove(path);
    cmd(commandBody("scene.reset"));
    runCmd("file.load", format(`{"path":"%s"}`, path));
    auto m = getJson("/api/model");
    assert(m["vertices"].array.length == verts.length && m["faces"].array.length == faces.length,
        format("rig: loaded %d verts / %d faces, wrote %d / %d", m["vertices"].array.length,
               m["faces"].array.length, verts.length, faces.length));
    assert(m["surfaces"].array.length == surfs.length,
        format("rig: loaded %d surfaces, wrote %d", m["surfaces"].array.length, surfs.length));
}

/// One hinge: two unit quads sharing the vertical edge x = `cx`, y in
/// [y0, y0 + 1], folded by `dihedral` (each face tilted half of it away from
/// +Z), wound toward +Z. Faces: L then R.
struct Hinge { V3[] v; uint[][] f; double cx; }

Hinge hinge(double cx, double y0, double dihedralDeg, uint base) {
    immutable double h = dihedralDeg / 2 * PI / 180;
    Hinge g;
    g.cx = cx;
    immutable float y1 = cast(float)(y0 + 1);
    g.v = [V3(cast(float)cx, cast(float)y0, 0), V3(cast(float)cx, y1, 0),
           V3(cast(float)(cx - cos(h)), cast(float)y0, cast(float)-sin(h)),
           V3(cast(float)(cx - cos(h)), y1, cast(float)-sin(h)),
           V3(cast(float)(cx + cos(h)), cast(float)y0, cast(float)-sin(h)),
           V3(cast(float)(cx + cos(h)), y1, cast(float)-sin(h))];
    uint[][] f = [[0u, 2, 3, 1], [0u, 1, 5, 4]];
    foreach (ref face; f) if (faceNormal(g.v, face).z < 0) { import std.algorithm : reverse; face.reverse(); }
    foreach (ref face; f) foreach (ref x; face) x += base;
    g.f = f;
    return g;
}

enum double kY0 = 0.3;   // the hinges sit above the grid's horizon row

/// H30 (left, faces 0/1) and H50 (right, faces 2/3), laterally offset.
void hingeRig(uint[] mats = null, Surf[] surfs = null, bool swapH30 = false) {
    auto a = hinge(-1.6, kY0, 30, 0), b = hinge(1.6, kY0, 50, 6);
    loadRig(a.v ~ b.v, a.f ~ b.f, mats, surfs);
    cmd("viewport.wireOverlay none");
    cmd("viewport.view Front");
    frameFence(null, 2);
    auto r = postJson("/api/camera?viewport=0", format(`{"focus":{"x":0,"y":%.3f,"z":0},"distance":7}`, kY0 + 0.5));
    assert(r["status"].str == "ok", "camera: " ~ r.toString);
    frameFence(null, 2);
}

// ---------------------------------------------------------------------------
// Predictions: the lit program's light function (`light_rig`, eye space)
// ---------------------------------------------------------------------------

/// The default material (`Surface.init`, captured): Kd = 0.6 × 0.8, spec 0.04,
/// glossiness 0.6 → rough 0.4 → Blinn exponent 128 (`specPowerForRoughness`).
enum double kKd = 0.6 * 0.8, kSpec = 0.04, kPower = 128;

V3 eyeN(V3 n, const ref Viewport vp) {
    return unit(V3(vp.view[0]*n.x + vp.view[4]*n.y + vp.view[8]*n.z,
                   vp.view[1]*n.x + vp.view[5]*n.y + vp.view[9]*n.z,
                   vp.view[2]*n.x + vp.view[6]*n.y + vp.view[10]*n.z));
}

/// Level (0..255) at world normal `n`, scaled by `dim` with light gain `gain`.
double level(V3 n, const ref Viewport vp, double dim = 1, double gain = 1) {
    immutable V3 ne = eyeN(n, vp);
    immutable V3 key = V3(-0.654509f, 0.587785f, 0.475528f), fill = V3(1, 0, 0);
    double blinn(V3 L, double nl) {
        if (nl <= 0) return 0;
        immutable V3 hv = unit(V3(L.x, L.y, L.z + 1));
        immutable double d = dt(ne, hv);
        return pow(d > 0 ? d : 0, kPower);
    }
    immutable double nk = dt(ne, key), nf = dt(ne, fill);
    immutable double dif = 0.7 * max(nk, 0.0) + 0.3 * max(nf, 0.0);
    immutable double spc = 0.7 * blinn(key, nk) + 0.3 * blinn(fill, nf);
    double c = (kKd * (0.15 + gain * dif) + gain * kSpec * spc) * dim;
    return 255.0 * (c > 1 ? 1 : c);
}

/// A 5×5 probe window centred `side` × 4 px off the edge of `g` at its mid
/// height, with the predicted mean for the FLAT and the SMOOTH stream there.
struct Window { int[2][] pts; double flat, smooth; }

Window window(ref Hinge g, int faceSide, double dim = 1, double gain = 1) {
    auto vp = viewportFromCameraMatrices();
    float ex, ey, fx, fy;
    immutable double ym = kY0 + 0.5;
    assert(projectToWindow(V3(cast(float)g.cx, cast(float)ym, 0), vp, ex, ey), "rig: edge behind the camera");
    immutable V3 far_ = faceSide < 0 ? g.v[2] : g.v[4];
    assert(projectToWindow(V3(far_.x, cast(float)ym, far_.z), vp, fx, fy), "rig: far edge behind the camera");
    immutable double widthPx = abs(fx - ex);
    assert(widthPx >= 60, format("rig: the hinge face spans only %.1f px", widthPx));
    immutable V3 nL = faceNormal(g.v, localFace(g, 0)), nR = faceNormal(g.v, localFace(g, 1));
    immutable V3 nF = faceSide < 0 ? nL : nR;
    immutable V3 nE = unit(add(nL, nR));
    foreach (n; [nL, nR])
        assert(eyeN(n, vp).z > 0.2, "rig: a hinge face does not face the camera");
    Window w;
    immutable int cxp = cast(int)round(ex) - vp.x + faceSide * 4, cyp = cast(int)round(ey) - vp.y;
    double sf = 0, ss = 0;
    foreach (dy; -2 .. 3) foreach (dx; -2 .. 3) {
        immutable int px = cxp + dx, py = cyp + dy;
        w.pts ~= [px, py];
        immutable double u = abs((px + vp.x + 0.5) - ex) / widthPx;
        sf += level(nF, vp, dim, gain);
        ss += level(unit(add(scl(nE, 1 - u), scl(nF, u))), vp, dim, gain);
    }
    w.flat = sf / 25;
    w.smooth = ss / 25;
    return w;
}

/// The face of `g` (0 = L, 1 = R) in `g.v`'s local indices.
uint[] localFace(ref Hinge g, size_t k) {
    uint[] f = g.f[k].dup;
    immutable uint base = min(g.f[0][0], g.f[0][1], g.f[0][2], g.f[0][3]);
    foreach (ref x; f) x -= base;
    return f;
}

/// Window mean of the red channel; floor first: all 25 samples on the surface
/// (none reads the background colour `bg`).
double probeMean(Window w, int cell = 0, int[3] bg = [-1, -1, -1]) {
    string q;
    foreach (i, p; w.pts) q ~= format("%s%d,%d", i ? ";" : "", p[0], p[1]);
    auto j = getJson(format("/api/viewport/probe?cell=%d&points=%s", cell, q));
    assert(j["renders"].type == JSONType.true_, "the probed cell is not rendering");
    double s = 0;
    size_t onSurface;
    foreach (e; j["points"].array) {
        assert(("error" in e) is null, "probe point refused: " ~ e.toString);
        immutable int r = cast(int)e["r"].integer, g = cast(int)e["g"].integer, b = cast(int)e["b"].integer;
        if (!(r == bg[0] && g == bg[1] && b == bg[2])) ++onSurface;
        s += r;
    }
    assert(onSurface == 25, format("probe floor: %d of 25 window samples are on the surface", onSurface));
    return s / 25;
}

/// The background colour: a cell corner far from the rig.
int[3] background() {
    auto j = getJson("/api/viewport/probe?cell=0&points=12,12");
    auto e = j["points"].array[0];
    return [cast(int)e["r"].integer, cast(int)e["g"].integer, cast(int)e["b"].integer];
}

enum double kTol = 2.5;   // window mean vs prediction (8-bit rounding + raster)

/// Assert the window reads `want` (smooth or flat), naming the other.
void expectSide(string what, Window w, bool wantSmooth, int[3] bg) {
    immutable double got = probeMean(w, 0, bg);
    immutable double want = wantSmooth ? w.smooth : w.flat, other = wantSmooth ? w.flat : w.smooth;
    writefln("[%s] %.2f (predicted %s %.2f, %s %.2f)", what, got, wantSmooth ? "smooth" : "flat", want,
             wantSmooth ? "flat" : "smooth", other);
    assert(abs(got - want) <= kTol,
        format("%s: reads %.2f, the %s stream predicts %.2f (the %s one %.2f)", what, got,
               wantSmooth ? "smooth" : "flat", want, wantSmooth ? "flat" : "smooth", other));
}

// ---------------------------------------------------------------------------
// (i) the implicit surface: H30 smooth, H50 hard; (ii) the angle command
// with undo/redo; (iii) smoothing off; (viii) the shaded backdrop.
// ---------------------------------------------------------------------------
unittest {
    if (!cellOn("i-iii")) return;
    hingeRig();
    auto a = hinge(-1.6, kY0, 30, 0), b = hinge(1.6, kY0, 50, 6);
    immutable bg = background();
    auto aL = window(a, -1), aR = window(a, 1), bL = window(b, -1), bR = window(b, 1);
    // Discrimination floor: each smooth/flat pair at least 6 levels apart.
    foreach (i, w; [aL, aR, bL, bR])
        assert(abs(w.smooth - w.flat) >= 6,
            format("rig floor: window %d smooth %.2f vs flat %.2f", i, w.smooth, w.flat));
    writefln("[i] margins H30 L %.2f R %.2f, H50 L %.2f R %.2f", abs(aL.smooth - aL.flat),
             abs(aR.smooth - aR.flat), abs(bL.smooth - bL.flat), abs(bR.smooth - bR.flat));
    expectSide("(i) H30 L", aL, true, bg);
    expectSide("(i) H30 R", aR, true, bg);
    expectSide("(i) H50 L", bL, false, bg);
    expectSide("(i) H50 R", bR, false, bg);

    cmd(`{"id":"history.clear"}`);
    immutable size_t d0 = undoDepth();
    cmd(attrBody(0, "smoothingAngle", 60));
    assert(undoDepth() == d0 + 1, "(ii) the angle command recorded no undo entry");
    frameFence(null, 2);
    expectSide("(ii) H50 L @60", bL, true, bg);
    // The same value again: refused, nothing recorded (the no-op contract).
    auto again = post(attrBody(0, "smoothingAngle", 60));
    assert(again["status"].str == "error" && undoDepth() == d0 + 1,
        "(ii) the same value twice was accepted: " ~ again.toString);
    cmd(commandBody("history.undo"));
    frameFence(null, 2);
    expectSide("(ii) H50 L undone", bL, false, bg);
    cmd(commandBody("history.redo"));
    frameFence(null, 2);
    expectSide("(ii) H50 L redone", bL, true, bg);

    cmd(attrBody(0, "smoothing", 0));
    frameFence(null, 2);
    expectSide("(iii) H30 L off", aL, false, bg);
    expectSide("(iii) H30 R off", aR, false, bg);

    // (viii) the rig becomes a background layer: still flat in the shaded backdrop.
    cmd(`{"id":"layer.add"}`);
    cmd(commandBody("viewport.backdropStyle", `{"value":"flat"}`));
    frameFence(null, 2);
    auto disp = getJson("/api/viewport/display")["cells"].array[0];
    auto bp = disp["plan"]["backdrop"];
    immutable double dim = num(bp["dim"]), gain = num(bp["lightGain"]);
    assert(bp["smoothNormals"].type == JSONType.true_, "(viii) premise: the backdrop plan is not smooth: " ~ bp.toString);
    auto vL = window(a, -1, dim, gain), vR = window(a, 1, dim, gain);
    immutable double flatStep = abs(vL.flat - vR.flat), smoothStep = abs(vL.smooth - vR.smooth);
    assert(flatStep - smoothStep >= 4, format("(viii) floor: flat step %.2f vs smooth step %.2f", flatStep, smoothStep));
    immutable double l = probeMean(vL, 0, bg), r = probeMean(vR, 0, bg);
    writefln("[viii] backdrop dim %.2f gain %.2f: L %.2f R %.2f step %.2f (flat %.2f, smooth %.2f)",
             dim, gain, l, r, abs(l - r), flatStep, smoothStep);
    assert(abs(abs(l - r) - flatStep) <= kTol,
        format("(viii) the backdrop H30 steps %.2f levels; flat predicts %.2f, smooth %.2f — "
             ~ "a background layer lost its surface's smoothing", abs(l - r), flatStep, smoothStep));
    cmd(commandBody("viewport.backdropStyle", `{"value":"same"}`));
}

// ---------------------------------------------------------------------------
// (iv) the ruling cells on a two-surface H30 (L face slot 0, R face slot 1, or
// swapped): the lower slot decides the pair for BOTH faces. Each cell first
// asserts that its separating loser predicts something ≥ 6 levels away.
// ---------------------------------------------------------------------------
enum Rule { Ruling, HS, F, M, FI, ASYM }

/// Whether face `k` (0 = L, 1 = R) of the hinge smooths with the other under `r`.
bool smooths(Rule r, uint[2] slot, Surf[2] s, size_t k, double dihedral) {
    immutable double c = cos(dihedral * PI / 180);
    double cosOf(uint sl) { return s[sl].on ? cos(s[sl].angle * PI / 180) : 2.0; }
    immutable uint sf = slot[k], sg = slot[1 - k], lo = min(sf, sg), hi = max(sf, sg);
    double t;
    final switch (r) {
        case Rule.Ruling: t = cosOf(lo); break;
        case Rule.HS:     t = cosOf(hi); break;
        case Rule.F:      t = cosOf(sf); break;
        case Rule.M:      t = max(cosOf(sf), cosOf(sg)); break;
        case Rule.FI:     t = cosOf(k == 0 ? sf : sg); break;
        case Rule.ASYM:   t = s[lo].on ? cosOf(lo) : cosOf(sf); break;
    }
    return c >= t;
}

struct RulingCell { string name; bool swap; Surf[2] s; Rule[] losers; }

unittest {
    immutable RulingCell[] cells = [
        RulingCell("b",    false, [Surf(true, 60), Surf(true, 20)], [Rule.HS, Rule.F, Rule.M]),
        RulingCell("b3",   false, [Surf(true, 20), Surf(true, 60)], [Rule.HS, Rule.F]),
        RulingCell("sw",   true,  [Surf(true, 20), Surf(true, 60)], [Rule.FI, Rule.HS, Rule.F]),
        RulingCell("c1",   false, [Surf(false, 40), Surf(true, 40)], [Rule.ASYM, Rule.HS, Rule.F]),
        RulingCell("c2",   false, [Surf(true, 40), Surf(false, 40)], [Rule.M, Rule.HS, Rule.F]),
        RulingCell("c2sw", true,  [Surf(true, 40), Surf(false, 40)], [Rule.FI, Rule.HS, Rule.F, Rule.M]),
    ];
    assert(cells.length == 6, "ruling cell population");
    foreach (c; cells) {
        if (!cellOn("iv-" ~ c.name)) continue;
        immutable uint[2] slot = c.swap ? [1u, 0u] : [0u, 1u];
        // Write the two surfaces as defaults, then set them through the command.
        hingeRig([slot[0], slot[1], 0, 0], [Surf(), Surf()]);
        foreach (int si; 0 .. 2) {
            setAttr(si, "smoothingAngle", c.s[si].angle);
            setAttr(si, "smoothing", c.s[si].on ? 1 : 0);
        }
        frameFence(null, 2);
        auto m = getJson("/api/model")["surfaces"].array;
        foreach (si; 0 .. 2)
            assert((m[si]["smoothing"].type == JSONType.true_) == c.s[si].on
                && abs(num(m[si]["smoothingAngle"]) - c.s[si].angle) < 1e-4,
                format("(iv) %s: slot %d reads %s", c.name, si, m[si].toString));
        auto a = hinge(-1.6, kY0, 30, 0);
        immutable bg = background();
        Window[2] w = [window(a, -1), window(a, 1)];
        // Each separating loser predicts some side >= 6 levels from the ruling.
        foreach (lo; c.losers) {
            double best = 0;
            foreach (k; 0 .. 2) {
                immutable bool rs = smooths(Rule.Ruling, slot, c.s, k, 30), ls = smooths(lo, slot, c.s, k, 30);
                if (rs != ls) best = max(best, abs(w[k].smooth - w[k].flat));
            }
            writefln("[iv %s] loser %s separated by %.2f levels", c.name, lo, best);
            assert(best >= 6, format("(iv) %s: the loser %s is not >= 6 levels from the ruling (%.2f)",
                                     c.name, lo, best));
        }
        foreach (k; 0 .. 2)
            expectSide(format("(iv) %s %s", c.name, k == 0 ? "L" : "R"), w[k],
                       smooths(Rule.Ruling, slot, c.s, k, 30), bg);
    }
}

// ---------------------------------------------------------------------------
// (v) C8e: `viewport.smooth` ANDs with the surface flag.
// ---------------------------------------------------------------------------
unittest {
    if (!cellOn("v")) return;
    scope(exit) cmd("viewport.smooth on");
    hingeRig();
    auto a = hinge(-1.6, kY0, 30, 0);
    immutable bg = background();
    auto w = window(a, -1);
    cmd("viewport.smooth off");
    frameFence(null, 2);
    expectSide("(v) viewport off, surface on", w, false, bg);
    cmd("viewport.smooth on");
    cmd(attrBody(0, "smoothing", 0));
    frameFence(null, 2);
    expectSide("(v) viewport on, surface off", w, false, bg);
    // Control: both on.
    cmd(commandBody("history.undo"));
    frameFence(null, 2);
    expectSide("(v) both on", w, true, bg);
}

// ---------------------------------------------------------------------------
// E5 (suite half): a fresh primitive's implicit slot, materialised by the
// command, draws the same pixel (materialised slot == implicit slot).
// ---------------------------------------------------------------------------
unittest {
    if (!cellOn("materialise")) return;
    cmd(commandBody("scene.reset", `{"empty":true}`));
    cmd("prim.cube cenX:0 cenY:0.5 cenZ:0 sizeX:1 sizeY:1 sizeZ:1 segmentsX:1 segmentsY:1 segmentsZ:1 radius:0");
    cmd("viewport.wireOverlay none");
    auto r = postJson("/api/camera", `{"azimuth":0.4,"elevation":0.3,"distance":4,"focus":{"x":0,"y":0.5,"z":0}}`);
    frameFence(null, 2);
    assert(getJson("/api/model")["surfaces"].array.length == 0, "materialise premise: the cube has a surface table");
    auto vp = viewportFromCameraMatrices();
    float px, py;
    assert(projectToWindow(V3(0, 0.5f, 0.5f), vp, px, py), "materialise: the front face is behind the camera");
    immutable int x = cast(int)px - vp.x, y = cast(int)py - vp.y;
    int readR() {
        auto j = getJson(format("/api/viewport/probe?cell=0&points=%d,%d", x, y));
        return cast(int)j["points"].array[0]["r"].integer;
    }
    immutable int before = readR();
    // Premise: the face reads the default material, not the old 0.8 grey.
    immutable double want = level(V3(0, 0, 1), vp);
    assert(abs(before - want) <= 2, format("materialise: the front face reads %d, Surface.init predicts %.2f",
                                           before, want));
    cmd(attrBody(0, "smoothing", 0));
    frameFence(null, 2);
    auto s = getJson("/api/model")["surfaces"].array;
    assert(s.length == 1 && s[0]["smoothing"].type == JSONType.false_,
        "materialise: the table is not one slot with smoothing off: " ~ getJson("/api/model")["surfaces"].toString);
    immutable int after = readR();
    assert(abs(after - before) <= 1,
        format("materialise: the front face moved from %d to %d — the materialised slot is not the implicit one",
               before, after));
}

// ---------------------------------------------------------------------------
// (vii) the cage path, per corner, no pixel: strip A0 A1 | B0 B1 (10° bends
// inside A and inside B, a 30° hinge A1|B0).
// ---------------------------------------------------------------------------
double[3] triple(JSONValue v) {
    auto a = v.array;
    return [a[0].floating, a[1].floating, a[2].floating];
}
double maxAbs3(double[3] a, double[3] b) {
    return max(abs(a[0] - b[0]), abs(a[1] - b[1]), abs(a[2] - b[2]));
}
double[3] d3(V3 v) { return [v.x, v.y, v.z]; }

enum double kEq = 2e-6;   // the face-VBO dump prints 6 decimals

unittest {
    if (!cellOn("vii")) return;
    // Polyline P0..P4 in XZ (segment headings 0, 10, 40, 50 degrees), extruded in Y.
    immutable double[4] head = [0, 10, 40, 50];
    V3[] p = [V3(-2, 0, 0)];
    foreach (hd; head) {
        immutable double r = hd * PI / 180;
        p ~= add(p[$ - 1], V3(cast(float)cos(r), 0, cast(float)-sin(r)));
    }
    V3[] v;
    foreach (q; p) { v ~= V3(q.x, cast(float)kY0, q.z); v ~= V3(q.x, cast(float)(kY0 + 1), q.z); }
    uint[][] f;
    foreach (uint i; 0 .. 4) {
        uint[] face = [2 * i, 2 * i + 2, 2 * i + 3, 2 * i + 1];
        if (faceNormal(v, face).z < 0) { import std.algorithm : reverse; face.reverse(); }
        f ~= face;
    }
    V3[4] n;
    foreach (i; 0 .. 4) n[i] = faceNormal(v, f[i]);
    bool atX(double[3] pos, V3 q) { return abs(pos[0] - q.x) < 1e-4 && abs(pos[2] - q.z) < 1e-4; }
    size_t faceOf(double[3] flat) {
        foreach (i; 0 .. 4) if (maxAbs3(flat, d3(n[i])) < 1e-4) return i;
        assert(false, format("(vii) a corner's flat normal %s matches no strip face", flat));
    }
    foreach (int variant; 0 .. 2) {
        // (vii-a): B = slot 0 OFF, A = slot 1 @40. (vii-b): A = slot 0 @40, B = slot 1 OFF.
        uint[] mats = variant == 0 ? [1u, 1, 0, 0] : [0u, 0, 1, 1];
        Surf[] surfs = variant == 0 ? [Surf(false, 40), Surf(true, 40)] : [Surf(true, 40), Surf(false, 40)];
        loadRig(v, f, mats, surfs);
        frameFence(null, 2);
        auto vbo = getJson("/api/gpu/face-vbo?normals=1");
        immutable size_t nc = cast(size_t)vbo["faceVertCount"].integer;
        assert(nc == 24 && vbo["smoothNormals"].array.length == nc,
            format("(vii) floor: %d fan corners, expected 24 (4 quads x 6)", nc));
        size_t bCorners;
        foreach (i; 0 .. nc) {
            immutable fi = faceOf(triple(vbo["flatNormals"].array[i]));
            if (fi >= 2) ++bCorners;
        }
        assert(bCorners == 12, format("(vii) floor: %d B fan corners, expected 12", bCorners));
        if (variant == 0) {
            foreach (i; 0 .. nc) {
                immutable fi = faceOf(triple(vbo["flatNormals"].array[i]));
                immutable pos = triple(vbo["positions"].array[i]), sm = triple(vbo["smoothNormals"].array[i]);
                if (fi >= 2)
                    assert(maxAbs3(sm, d3(n[fi])) <= kEq,
                        format("(vii-a) B face %d corner at %s is %s, not flat %s — B is the lower slot, OFF",
                               fi, pos, sm, d3(n[fi])));
            }
            size_t hingeA, interiorA;
            foreach (i; 0 .. nc) {
                immutable fi = faceOf(triple(vbo["flatNormals"].array[i]));
                immutable pos = triple(vbo["positions"].array[i]), sm = triple(vbo["smoothNormals"].array[i]);
                if (fi == 1 && atX(pos, p[2])) {
                    ++hingeA;
                    assert(maxAbs3(sm, d3(n[1])) <= kEq && maxAbs3(sm, d3(unit(add(n[1], n[2])))) > 1e-3,
                        format("(vii-a) A1's hinge corner %s is %s: it must exclude B0 (A-only %s)",
                               pos, sm, d3(n[1])));
                }
                if (fi == 1 && atX(pos, p[1])) {
                    ++interiorA;
                    assert(maxAbs3(sm, d3(n[1])) > 1e-3,
                        format("(vii-a) control: A1's interior corner %s stayed flat — A does not smooth", pos));
                }
            }
            assert(hingeA >= 2 && interiorA >= 2, format("(vii-a) floor: %d hinge / %d interior A1 corners",
                                                         hingeA, interiorA));
        } else {
            // Must-stay-flat corners first [E7].
            size_t stay, moved;
            foreach (i; 0 .. nc) {
                immutable fi = faceOf(triple(vbo["flatNormals"].array[i]));
                immutable pos = triple(vbo["positions"].array[i]), sm = triple(vbo["smoothNormals"].array[i]);
                if (fi >= 2 && !(fi == 2 && atX(pos, p[2]))) {
                    ++stay;
                    assert(maxAbs3(sm, d3(n[fi])) <= kEq,
                        format("(vii-b) B face %d corner at %s is %s, not flat — the pair B0|B1 is decided "
                             ~ "by B's slot (OFF)", fi, pos, sm));
                }
            }
            foreach (i; 0 .. nc) {
                immutable fi = faceOf(triple(vbo["flatNormals"].array[i]));
                immutable pos = triple(vbo["positions"].array[i]), sm = triple(vbo["smoothNormals"].array[i]);
                if (fi == 2 && atX(pos, p[2])) {
                    ++moved;
                    assert(maxAbs3(sm, d3(n[2])) > 1e-3,
                        format("(vii-b) B0's hinge corner %s stayed flat — the lower ON slot (A) must "
                             ~ "smooth it", pos));
                }
            }
            assert(stay >= 8 && moved >= 2, format("(vii-b) floor: %d stay-flat / %d hinge B0 corners", stay, moved));
        }
    }
}

// ---------------------------------------------------------------------------
// (vi) three-producer differential: the subpatch fan-out (GPU) vs the CPU
// rebake, on a cube CAGE (the surface is the limit surface, not a cube) whose
// six faces carry slots 2, 0, 1, 0, 2, 1 (0 OFF, 1 @25, 2 @60).
// ---------------------------------------------------------------------------
void waitPreviewSettled(bool wantActive = true, int timeoutMs = 30_000) {
    foreach (_; 0 .. timeoutMs / 20) {
        auto p = getJson("/api/subpatch/preview");
        if ((p["active"].type == JSONType.true_) == wantActive && p["pending"].type != JSONType.true_) {
            frameFence(null, 2);
            return;
        }
        Thread.sleep(20.msecs);
    }
    assert(false, "subpatch preview did not settle");
}

void select(string mode, int[] indices) {
    string body = `{"mode":"` ~ mode ~ `","indices":[`;
    foreach (i, idx; indices) body ~= (i ? "," : "") ~ idx.to!string;
    cmd(commandBody("mesh.select", body ~ "]}"));
}

string previewWriter() { return getJson("/api/subpatch/preview")["displayWriter"].str; }

enum size_t kPreviewCorners = 2304;   // the cube cage's preview: 6 x 8 x 8 quads x 6 fan corners

/// Drag the cage's selection (held), read the GPU-written VBO, release, rebake
/// on the CPU, read again; compare per corner. Returns the CPU payload.
JSONValue dragAndCompare(string label) {
    cmd("tool.set move on");
    frameFence(null, 2);
    auto c = fetchCamera();
    double gx, gy;
    bool found;
    fetchHandlePart(0, gx, gy, found);
    assert(found, label ~ ": grab handle missing");
    immutable int x0 = cast(int)(gx + 0.5), y0 = cast(int)(gy + 0.5), x1 = x0 + 50, y1 = y0 - 40;
    playAndWait(buildDragDownLog(c.vpX, c.vpY, c.width, c.height, x0, y0));
    playAndWait(buildDragMotionLog(c.vpX, c.vpY, c.width, c.height, x0, y0, x1, y1, 8));
    frameFence(null, 2);
    // Path control FIRST [E10].
    if (previewWriter() != "gpuFanOut")
        assert(false, format("%s: fan-out never ran: cell cannot witness (writer %s)", label, previewWriter()));
    auto gpu = getJson("/api/gpu/face-vbo?normals=1");
    playAndWait(buildDragUpLog(c.vpX, c.vpY, c.width, c.height, x1, y1));
    cmd("tool.set move off");
    waitPreviewSettled();
    cmd("select.typeFrom polygon");
    select("polygons", []);
    cmd(`{"id":"mesh.subpatch_toggle"}`);
    waitPreviewSettled(false);
    cmd(`{"id":"mesh.subpatch_toggle"}`);
    waitPreviewSettled();
    assert(previewWriter() == "fullUpload", label ~ ": the rebake was not a CPU full upload");
    auto cpu = getJson("/api/gpu/face-vbo?normals=1");
    immutable size_t n = cast(size_t)gpu["faceVertCount"].integer;
    assert(n == kPreviewCorners && cast(size_t)cpu["faceVertCount"].integer == n
        && gpu["smoothNormals"].array.length == n && cpu["smoothNormals"].array.length == n,
        format("%s floor: faceVertCount %d / %d (expected %d)", label, n, cpu["faceVertCount"].integer,
               kPreviewCorners));
    size_t differ, equal;
    double dPos = 0, dSmooth = 0;
    size_t worst;
    foreach (i; 0 .. n) {
        dPos = max(dPos, maxAbs3(triple(gpu["positions"].array[i]), triple(cpu["positions"].array[i])));
        immutable sm = triple(cpu["smoothNormals"].array[i]), fl = triple(cpu["flatNormals"].array[i]);
        if (maxAbs3(sm, fl) > 1e-3) ++differ;
        else if (maxAbs3(sm, fl) <= 1e-6) ++equal;
        immutable double d = maxAbs3(triple(gpu["smoothNormals"].array[i]), sm);
        if (d > dSmooth) { dSmooth = d; worst = i; }
    }
    writefln("[vi %s] %d corners: smooth != flat %d, smooth == flat %d; max |gpu-cpu| pos %.2e smooth %.2e",
             label, n, differ, equal, dPos, dSmooth);
    assert(dPos <= 1e-4, format("%s premise: the GPU and CPU surfaces differ by %.2e", label, dPos));
    // Both populations non-empty: a constant threshold or an ignored slot cannot
    // pass. Pinned to the measured split of drag 1 (2026-10-02: 1532 / 754).
    assert(differ >= 100 && equal >= 100,
        format("%s floor: %d smoothed / %d flat corners — the cell cannot see the policy", label, differ, equal));
    if (label == "drag 1")
        assert(differ == 1532 && equal == 754,
            format("%s: %d smoothed / %d flat corners, measured 1532 / 754", label, differ, equal));
    assert(dSmooth <= 1e-4,
        format("%s: corner %d smooth normal %s from the GPU fan-out, %s from the CPU rebake (|d| %.2e)", label,
               worst, triple(gpu["smoothNormals"].array[worst]), triple(cpu["smoothNormals"].array[worst]), dSmooth));
    return cpu;
}

/// The cube cage with three slots under a live subpatch preview, vertices
/// 0-3 selected, camera close in. `extra` appends unused slots (3, ...).
void prepareCage(Surf[] extra = null, void delegate() beforeTab = null,
                 void delegate() afterTab = null) {
    V3[] cv = [V3(-0.5f, -0.5f, -0.5f), V3(0.5f, -0.5f, -0.5f), V3(0.5f, 0.5f, -0.5f), V3(-0.5f, 0.5f, -0.5f),
               V3(-0.5f, -0.5f, 0.5f), V3(0.5f, -0.5f, 0.5f), V3(0.5f, 0.5f, 0.5f), V3(-0.5f, 0.5f, 0.5f)];
    uint[][] cf = [[0u, 3, 2, 1], [4u, 5, 6, 7], [0u, 4, 7, 3], [1u, 2, 6, 5], [3u, 7, 6, 2], [0u, 1, 5, 4]];
    loadRig(cv, cf, [2u, 0, 1, 0, 2, 1], [Surf(false, 40), Surf(true, 25), Surf(true, 60)] ~ extra);
    cmd("tool.pipe.attr snap enabled false");
    cmd("tool.pipe.attr symmetry enabled false");
    cmd("select.typeFrom polygon");
    select("polygons", []);
    if (beforeTab !is null) beforeTab();
    cmd(`{"id":"mesh.subpatch_toggle"}`);
    if (afterTab !is null) afterTab();
    waitPreviewSettled();
    cmd("select.typeFrom vertex");
    select("vertices", [0, 1, 2, 3]);
    auto r = postJson("/api/camera", `{"distance":1.5,"focus":{"x":0,"y":0,"z":0}}`);
    assert(r["status"].str == "ok", "camera write failed: " ~ r.toString);
    frameFence(null, 2);
}

unittest {
    if (!cellOn("vi")) return;
    prepareCage();
    dragAndCompare("drag 1");
}

/// Corners whose smooth normal differs (> 1e-3) between two face-VBO reads.
size_t smoothChanged(JSONValue a, JSONValue b) {
    size_t n;
    foreach (i; 0 .. kPreviewCorners)
        if (maxAbs3(triple(a["smoothNormals"].array[i]), triple(b["smoothNormals"].array[i])) > 1e-3) ++n;
    return n;
}

/// The live preview VBO equals a CPU rebake (Tab off/on) of the same cage, per
/// corner; returns the rebake.
JSONValue expectRebakeEqual(string label, JSONValue live) {
    cmd("select.typeFrom polygon");
    select("polygons", []);
    cmd(`{"id":"mesh.subpatch_toggle"}`);
    waitPreviewSettled(false);
    cmd(`{"id":"mesh.subpatch_toggle"}`);
    waitPreviewSettled();
    auto cpu = getJson("/api/gpu/face-vbo?normals=1");
    assert(cast(size_t)cpu["faceVertCount"].integer == kPreviewCorners,
        format("%s floor: the rebake has %d corners", label, cpu["faceVertCount"].integer));
    double d = 0, dPos = 0;
    foreach (i; 0 .. kPreviewCorners) {
        d = max(d, maxAbs3(triple(live["smoothNormals"].array[i]), triple(cpu["smoothNormals"].array[i])));
        dPos = max(dPos, maxAbs3(triple(live["positions"].array[i]), triple(cpu["positions"].array[i])));
    }
    assert(dPos <= 1e-4, format("%s: the refreshed preview's positions differ from a rebake by %.2e "
                              ~ "(uploaded from stale preview vertices)", label, dPos));
    assert(d <= 1e-4, format("%s: the refreshed preview differs from a rebake of the same cage by %.2e "
                           ~ "(its material data or policy is stale)", label, d));
    return cpu;
}

// (vi) Material route: a Material-only commit (topology unchanged) takes
// `SubpatchPreview.rebuildIfStale`'s fast path, which must refresh the
// preview's material data (`refreshMaterialData`: surfaces, per-face tags, the
// fan-out's slot TBO + cosines) and force the full preview upload. Red before
// the fix: 0 corners changed (2026-10-02).
unittest {
    if (!cellOn("vi-material")) return;
    prepareCage();
    auto cpu1 = dragAndCompare("drag 1");
    // The Material route: slot 1 off; the policy must reach the preview.
    cmd(attrBody(1, "smoothing", 0));
    waitPreviewSettled();
    auto live = getJson("/api/gpu/face-vbo?normals=1");
    immutable size_t flipped = smoothChanged(cpu1, live);
    writefln("[vi] slot 1 off: %d corners changed", flipped);
    assert(previewWriter() == "fullUpload",
        "(vi) the Material commit did not take the full preview upload: writer " ~ previewWriter());
    assert(flipped >= 1, "(vi) the policy edit never reached the preview");
    assert(flipped == 836, format("(vi) slot 1 off changed %d corners, measured 836 (2026-10-03)", flipped));
    expectRebakeEqual("(vi) slot 1 off", live);
    // The fan-out's policy (slot TBO + cosines) must follow too: drag 2 compares
    // the GPU-written VBO with a rebake under the edited table.
    cmd("select.typeFrom vertex");
    select("vertices", [0, 1, 2, 3]);
    dragAndCompare("drag 2");
}

/// A held move drag of the selection, released, with NO rebake after it: the
/// fan-out leaves the preview's CPU vertices behind the cage.
void dragOnly(string label) {
    cmd("tool.set move on");
    frameFence(null, 2);
    auto c = fetchCamera();
    double gx, gy;
    bool found;
    fetchHandlePart(0, gx, gy, found);
    assert(found, label ~ ": grab handle missing");
    immutable int x0 = cast(int)(gx + 0.5), y0 = cast(int)(gy + 0.5), x1 = x0 + 50, y1 = y0 - 40;
    playAndWait(buildDragDownLog(c.vpX, c.vpY, c.width, c.height, x0, y0));
    playAndWait(buildDragMotionLog(c.vpX, c.vpY, c.width, c.height, x0, y0, x1, y1, 8));
    frameFence(null, 2);
    assert(previewWriter() == "gpuFanOut", format("%s: fan-out never ran (writer %s)", label, previewWriter()));
    playAndWait(buildDragUpLog(c.vpX, c.vpY, c.width, c.height, x1, y1));
    cmd("tool.set move off");
    waitPreviewSettled();
}

/// The centre pixel of cell 0.
int[3] centrePixel() {
    auto vp = viewportFromCameraMatrices();
    auto e = getJson(format("/api/viewport/probe?cell=0&points=%d,%d", vp.width / 2, vp.height / 2))
        ["points"].array[0];
    assert(("error" in e) is null, "centre probe refused: " ~ e.toString);
    return [cast(int)e["r"].integer, cast(int)e["g"].integer, cast(int)e["b"].integer];
}

/// Corners of a face-VBO read whose smooth normal leaves the flat one (> 1e-3).
size_t smoothedCorners(JSONValue v) {
    size_t n;
    foreach (i; 0 .. kPreviewCorners)
        if (maxAbs3(triple(v["smoothNormals"].array[i]), triple(v["flatNormals"].array[i])) > 1e-3) ++n;
    return n;
}

enum Surf kRedOff = Surf(false, 40, [0.9, 0.1, 0.1]);   // slot 3 of the re-tag cells

/// Premises of the re-tag cells, on the live preview before the re-tag: it
/// smooths (slots 1 and 2 are on) and the centre pixel is the grey default.
void expectGreySmooth(string label) {
    immutable size_t n = smoothedCorners(getJson("/api/gpu/face-vbo?normals=1"));
    immutable int[3] p = centrePixel();
    assert(n >= 100, format("%s premise: %d smoothed corners before the re-tag", label, n));
    assert(abs(p[0] - p[1]) <= 3 && p[0] > 20, format("%s premise: the centre pixel %s is not grey", label, p));
}

/// After every face went to slot 3 (red, OFF): no corner smooths, the centre
/// is red, and a rebake of the same cage agrees.
void expectRedFlat(string label) {
    auto live = getJson("/api/gpu/face-vbo?normals=1");
    immutable size_t n = smoothedCorners(live);
    immutable int[3] p = centrePixel();
    writefln("[%s] smoothed corners after the re-tag %d; centre %s", label, n, p);
    assert(n == 0, format("%s: %d of %d preview corners still smooth after re-tagging every face to an OFF "
                        ~ "slot", label, n, kPreviewCorners));
    assert(p[0] > p[1] + 40, format("%s: the centre pixel %s did not take the re-tagged slot's red", label, p));
    expectRebakeEqual(label, live);
}

void retagAll(int slot) {
    cmd("select.typeFrom polygon");
    select("polygons", []);
    runCmd("mesh.setMaterial", format(`{"materialId":%d}`, slot));
}

// (vi) re-tag route: `mesh.setMaterial` on the cage (all faces -> slot 3, red,
// smoothing OFF) reaches the live preview through the same Material trigger:
// every corner turns flat and the centre pixel turns red. A drag first, so the
// preview's CPU vertices are behind the cage when the full upload reads them.
unittest {
    if (!cellOn("vi-retag")) return;
    prepareCage([kRedOff]);
    dragOnly("(vi-retag)");
    expectGreySmooth("(vi-retag)");
    retagAll(3);
    waitPreviewSettled();
    expectRedFlat("(vi-retag)");
    // A SUBSET re-tag (cage faces 0 and 3 -> slot 1, on @25): each preview face
    // takes its OWN cage face's tag (`trace.faceOrigin`), per the rebake.
    cmd("select.typeFrom polygon");
    select("polygons", [0, 3]);
    runCmd("mesh.setMaterial", `{"materialId":1}`);
    waitPreviewSettled();
    auto live = getJson("/api/gpu/face-vbo?normals=1");
    immutable size_t n = smoothedCorners(live);
    writefln("[(vi-retag) subset] smoothed corners %d", n);
    assert(n >= 100 && n < kPreviewCorners / 2,
        format("(vi-retag) subset: %d smoothed corners — two of six faces on a smoothing slot", n));
    expectRebakeEqual("(vi-retag) subset", live);
    assert(n == 910, format("(vi-retag) subset: %d smoothed corners, measured 910 (2026-10-03)", n));
}

// (vi) after the re-tag, a drag: the GPU fan-out must read the re-uploaded slot
// TBO (`OsdAccel.refreshSmoothPolicy`), not the install-time tags.
unittest {
    if (!cellOn("vi-retag-drag")) return;
    prepareCage([kRedOff]);
    expectGreySmooth("(vi-retag-drag)");
    retagAll(3);
    waitPreviewSettled();
    cmd("select.typeFrom vertex");
    select("vertices", [0, 1, 2, 3]);
    dragOnly("(vi-retag-drag)");
    expectRedFlat("(vi-retag-drag)");
}

// (vi) the re-tag lands while the FIRST preview build is in flight (reception
// held): the build's snapshot carries the dispatch-time tags, so the install
// must re-copy the cage's.
unittest {
    if (!cellOn("vi-flight")) return;
    prepareCage([kRedOff], () {
        auto h = postJson("/api/subpatch/hold", `{"ms":-1,"ceilingMs":0}`);
        assert(h["status"].str == "ok", "/api/subpatch/hold failed: " ~ h.toString);
    }, () {
        scope(exit) postJson("/api/subpatch/hold", `{"ms":0,"ceilingMs":0}`);
        frameFence(null, 2);
        auto p = getJson("/api/subpatch/preview");
        assert(p["pending"].type == JSONType.true_, "(vi-flight) premise: no build in flight: " ~ p.toString);
        retagAll(3);
    });
    expectRedFlat("(vi-flight)");
}

// (vi) the re-tag lands while the preview is OFF and Tab resurrects the cached
// preview (`reusablePreviewKey`, which folds no material).
unittest {
    if (!cellOn("vi-reuse")) return;
    prepareCage([kRedOff]);
    expectGreySmooth("(vi-reuse)");
    cmd("select.typeFrom polygon");
    select("polygons", []);
    immutable long builds0 = getJson("/api/subpatch/preview")["builds"].integer;
    cmd(`{"id":"mesh.subpatch_toggle"}`);
    waitPreviewSettled(false);
    retagAll(3);
    cmd(`{"id":"mesh.subpatch_toggle"}`);
    waitPreviewSettled();
    assert(getJson("/api/subpatch/preview")["builds"].integer == builds0,
        "(vi-reuse) premise: Tab rebuilt the preview instead of resurrecting it");
    expectRedFlat("(vi-reuse)");
}
