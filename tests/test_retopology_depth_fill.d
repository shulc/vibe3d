// test_retopology_depth_fill.d — the per-item draw bracket under the
// retopology display mode: the depth clear at the head of the primary's draw,
// and its face pass (translucent, lit, back faces culled by screen winding,
// submitted in REVERSE polygon order).
//
// Rig: OPEN quads only, two layers. Layer 0 (background) is one big +Z quad
// P1 at z = 0. Layer 1 (the primary, the ONLY foreground layer — later
// multi-item work cannot change these values) carries every probed polygon:
//   over P1:   A z=+0.5, B z=-0.5 (behind P1), H z=-30, C slanted across P1,
//              F reversed winding, K (front) partly behind a reversed F2;
//   over the empty viewport: G z=+0.5, two D/E stacks (v1 back polygon
//              created FIRST, v2 front polygon first), a three-high stack
//              created front-to-back, and Q, the oblique quad whose facing
//              differs between the orthographic and the perspective eye.
// Front orthographic camera unless a cell says otherwise. Backdrop `flat`.
// Every "under" value is PROBED with layer 1 hidden (mode on, so the backdrop
// carries the mode's gain) — the clear colour included; nothing is typed.
//
// TOLERANCES come from 8-bit quantisation: every read value is +-0.5 LSB and
// each derived quantity carries its propagated error, stated beside it.
module test_retopology_depth_fill;

import http_client : getJson, postJson, quiesce, frameFence, waitPlaybackProcessed;
import http_command_helpers : commandBody;
import drag_helpers : viewportFromCameraMatrices, projectToWindow,
                      Viewport, DHVec3 = Vec3;
import std.json;
import std.format : format;
import std.math : abs, round, cos, sin, sqrt, pow, PI;
import std.algorithm : max, min;
import std.conv : to;
import std.stdio : writeln, writefln;

void main() {}

// Our lighting constants (the literals `LitShader.useProgram` uploads) — OURS,
// used only for the specular term, which is below 1 LSB on this rig.
private enum double kAmbient  = 0.20;
private enum double kSpecStr  = 0.25;
private enum double kSpecPow  = 32.0;
private immutable double[3] kLightRaw = [0.6, 1.0, 0.5];
private enum double kGain = 5.0 / 3.0;   // fixture light_gain
private enum double kFace = 0.2;         // retopology face colour (scheme row)
/// The scheme's selection colour for edges (the occluded-pass tests' value).
private immutable int[3] kSel = [255, 168, 41];

private void settle() { quiesce(); frameFence(null, 2); }
private JSONValue cmdRaw(string body) { return postJson("/api/command", body); }
private void cmdOk(string body) {
    auto r = cmdRaw(body);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "command failed: " ~ body ~ " -> " ~ r.toString);
}
private void cmd(string id, string params) { cmdOk(commandBody(id, params)); settle(); }
private void cmd(string id) { cmdOk(commandBody(id)); settle(); }

private double num(JSONValue v) {
    switch (v.type) {
        case JSONType.float_:   return v.floating;
        case JSONType.integer:  return cast(double) v.integer;
        case JSONType.uinteger: return cast(double) v.uinteger;
        default: assert(false, "expected a number, got " ~ v.toString);
    }
}
private bool jb(JSONValue v) {
    assert(v.type == JSONType.true_ || v.type == JSONType.false_,
        "expected a bool, got " ~ v.toString);
    return v.type == JSONType.true_;
}

// ---------------------------------------------------------------------------
// Rig geometry
// ---------------------------------------------------------------------------
private enum double kH = 0.3;   // half-size of the small probed quads

/// One quad: centre, half-size, z at its four corners (bottom-left,
/// bottom-right, top-right, top-left), counter-clockwise from +Z unless
/// `reversed`.
private struct Quad {
    string    name;
    double[3] c;
    double    half;
    double[4] dz;      // per-corner z offset from c[2]
    bool      reversed;
}

private double[3][4] corners(Quad q) {
    immutable double[2][4] xy = [[-q.half, -q.half], [q.half, -q.half],
                                 [q.half, q.half], [-q.half, q.half]];
    double[3][4] o;
    foreach (k; 0 .. 4)
        o[k] = [q.c[0] + xy[k][0], q.c[1] + xy[k][1], q.c[2] + q.dz[k]];
    return o;
}

private JSONValue meshJson(Quad[] qs) {
    JSONValue[] verts, faces;
    foreach (q; qs) {
        auto cs = corners(q);
        long[] f;
        foreach (p; cs) {
            verts ~= JSONValue([p[0], p[1], p[2]]);
            f ~= cast(long)(verts.length - 1);
        }
        if (q.reversed) f = [f[3], f[2], f[1], f[0]];
        faces ~= JSONValue(f);
    }
    return JSONValue(["vertices": JSONValue(verts), "faces": JSONValue(faces)]);
}

private Quad flat(string n, double x, double y, double z, double half = kH,
                  bool rev = false) {
    return Quad(n, [x, y, z], half, [0, 0, 0, 0], rev);
}

// The background: one big +Z quad over the left half of the view.
private immutable Quad kP1 = Quad("P1", [-1.5, 0.9, 0.0], 1.7, [0, 0, 0, 0], false);

// C's corners: z = +0.2 at its bottom edge, -0.2 at its top, so its lower
// half is in front of P1 and its upper half behind; normal (0, 0.447, 0.894).
// Q's normal is (cos 10, 0, -sin 10): back-facing for the +Z orthographic eye,
// front-facing for a perspective eye at distance < 17 on +Z (cell 9).
private Quad[] fgQuads() {
    // Q's corners are built in `meshJsonFg` (a tilted plane, not a z offset).
    Quad q = Quad("Q", [-3.0, -1.3, 0.0], kH, [0, 0, 0, 0], false);
    return [
        flat("A", -2.6, 1.5, 0.5),                                   // 0
        flat("B", -1.8, 1.5, -0.5),                                  // 1
        flat("H", -1.0, 1.5, -30.0),                                 // 2
        Quad("C", [-2.4, 0.5, 0.0], kH, [0.2, 0.2, -0.2, -0.2], false), // 3
        flat("F", -1.6, 0.5, 0.5, kH, true),                         // 4
        flat("K", -0.6, 0.4, 0.2),                                   // 5
        Quad("F2", [-0.6, 0.75, 0.6], kH, [0, 0, 0, 0], true),       // 6
        flat("G", 1.0, 1.5, 0.5),                                    // 7
        flat("E1", 1.9, 1.5, 0.0, 0.2),                              // 8  v1: back first
        flat("D1", 1.9, 1.5, 0.5, 0.35),                             // 9
        flat("D2", 1.9, 0.4, 0.5, 0.35),                             // 10 v2: front first
        flat("E2", 1.9, 0.4, 0.0, 0.2),                              // 11
        flat("S0", 2.9, 1.5, 1.0),                                   // 12 front, created first
        flat("S1", 2.9, 1.5, 0.5),                                   // 13
        flat("S2", 2.9, 1.5, 0.0),                                   // 14 back, created last
        q,                                                           // 15
    ];
}

private JSONValue meshJsonFg(Quad[] qs) {
    JSONValue[] verts, faces;
    immutable double s10 = sin(10.0 * PI / 180.0), c10 = cos(10.0 * PI / 180.0);
    foreach (q; qs) {
        double[3][4] cs;
        if (q.name == "Q") {
            // In-plane axes u = (s10, 0, c10) and v = (0, 1, 0); u x v =
            // (-c10, 0, s10), so the CCW order (-u-v, +u-v, +u+v, -u+v) faces
            // (-c10, 0, s10) and the REVERSED order faces n = (c10, 0, -s10).
            immutable double[2][4] uv = [[-1, -1], [1, -1], [1, 1], [-1, 1]];
            foreach (k; 0 .. 4)
                cs[k] = [q.c[0] + uv[k][0] * q.half * s10,
                         q.c[1] + uv[k][1] * q.half,
                         q.c[2] + uv[k][0] * q.half * c10];
        } else cs = corners(q);
        long[] f;
        foreach (p; cs) {
            verts ~= JSONValue([p[0], p[1], p[2]]);
            f ~= cast(long)(verts.length - 1);
        }
        if (q.reversed || q.name == "Q") f = [f[3], f[2], f[1], f[0]];
        faces ~= JSONValue(f);
    }
    return JSONValue(["vertices": JSONValue(verts), "faces": JSONValue(faces)]);
}

private int idxOf(Quad[] qs, string n) {
    foreach (i, q; qs) if (q.name == n) return cast(int) i;
    assert(false, "rig: no quad " ~ n);
}

private struct Rig {
    Quad[]   fg;
    Viewport vp;
    double   base;
    double[3] eye;
}

private int[2] toPx(double[3] w, ref Viewport vp) {
    float px, py;
    assert(projectToWindow(DHVec3(cast(float) w[0], cast(float) w[1], cast(float) w[2]),
                           vp, px, py), "rig point projects behind the camera");
    return [cast(int) round(px) - vp.x, cast(int) round(py) - vp.y];
}

private void frontOrtho() {
    cmdOk("viewport.view Front");
    settle();
    auto cr = postJson("/api/camera?viewport=0",
        `{"focus":{"x":0,"y":0,"z":0},"distance":9}`);
    assert(cr["status"].str == "ok", "camera: " ~ cr.toString);
    settle();
}

private Rig buildRig() {
    cmdOk(commandBody("scene.reset"));
    cmdOk(`{"id":"history.clear"}`);
    cmdOk(commandBody("viewport.layout", `"Single"`));
    Quad[] p1 = [cast(Quad) kP1];
    cmdOk(commandBody("scene.loadMesh", meshJson(p1).toString));
    cmdOk(`{"id":"layer.add"}`);
    auto fg = fgQuads();
    cmdOk(commandBody("scene.loadMesh", meshJsonFg(fg).toString));
    frontOrtho();
    cmd("viewport.displayStyle", `{"value":"shaded"}`);
    cmd("viewport.backdropStyle", `{"value":"flat"}`);

    auto L = getJson("/api/layers");
    auto layers = L["layers"].array;
    assert(layers.length == 2, "rig: expected exactly two layers, got " ~ L.toString);
    assert(L["active"].integer == 1, "rig: layer 1 must be the primary: " ~ L.toString);
    assert(jb(layers[0]["visible"]) && !jb(layers[0]["primary"])
        && !jb(layers[0]["selected"]),
        "rig: layer 0 must be a visible, unselected background layer: " ~ L.toString);
    immutable faceCount = getJson("/api/model")["faces"].array.length;
    assert(faceCount == fg.length,
        format("rig: layer 1 has %s faces, built %s", faceCount, fg.length));

    Rig r;
    r.fg = fg;
    auto s0 = getJson("/api/model?layer=0")["surfaces"].array;
    if (s0.length == 0) r.base = 0.8;
    else {
        auto bc = s0[0]["baseColor"].array;
        assert(num(bc[0]) == num(bc[1]) && num(bc[1]) == num(bc[2]),
            "rig: expected a grey base colour, got " ~ s0[0].toString);
        r.base = num(bc[0]);
    }
    auto cam = getJson("/api/camera?viewport=0");
    assert(cam["projKind"].str != "Perspective" && cam["viewPreset"].str == "Front",
        "rig: the cell must be in the orthographic Front view: " ~ cam.toString);
    r.vp = viewportFromCameraMatrices();
    assert(r.vp.proj[15] != 0.0f, "rig: the Front view must be orthographic");
    r.eye = [r.vp.eye.x, r.vp.eye.y, r.vp.eye.z];
    assert(r.eye[2] > 1.0 && abs(r.eye[0]) < 0.01 && abs(r.eye[1]) < 0.01,
        format("rig: the eye must sit on +Z (a larger z is nearer), got %s", r.eye));
    // Every probed centre inside the cell with margin, and each small quad at
    // least 8 px across its half so a centre probe cannot touch an edge.
    foreach (q; fg) {
        auto p = toPx(q.c, r.vp);
        assert(p[0] > 12 && p[1] > 12 && p[0] < r.vp.width - 12 && p[1] < r.vp.height - 12,
            format("rig: quad %s projects to %s, outside the %sx%s cell",
                   q.name, p, r.vp.width, r.vp.height));
    }
    auto e0 = toPx([0.0, 0.0, 0.0], r.vp), e1 = toPx([kH, 0.0, 0.0], r.vp);
    assert(abs(e1[0] - e0[0]) >= 8,
        format("rig: a %.1f-unit half-size is only %s px", kH, abs(e1[0] - e0[0])));
    parkPointer(r);
    return r;
}

/// Move the pointer clear of every polygon so no rollover tint is drawn.
private void parkPointer(ref Rig r) {
    string log = format(`{"t":0,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,`
        ~ `"fovY":0.785398}`, r.vp.x, r.vp.y, r.vp.width, r.vp.height) ~ "\n";
    foreach (i; 0 .. 3)
        log ~= format(`{"t":%d,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,`
            ~ `"state":0,"mod":0}`, 30 + i * 20, r.vp.x + r.vp.width - 8,
            r.vp.y + r.vp.height - 8) ~ "\n";
    auto pr = postJson("/api/play-events", log);
    assert(pr["status"].str == "success", "park: /api/play-events failed: " ~ pr.toString);
    waitPlaybackProcessed();
    settle();
}

// ---------------------------------------------------------------------------
// Probing
// ---------------------------------------------------------------------------
private struct Px { int[4] c; }   // r, g, b, a

private Px[] probe(int[2][] pts) {
    string q = "/api/viewport/probe?cell=0&points=";
    foreach (k, p; pts) q ~= format("%s%d,%d", k ? ";" : "", p[0], p[1]);
    auto j = getJson(q);
    assert("error" !in j, "probe failed: " ~ j.toString);
    assert(jb(j["renders"]), "the probed cell is not rendered; every reading is void");
    Px[] o;
    foreach (e; j["points"].array) {
        assert("error" !in e, "probe point unreadable: " ~ e.toString);
        o ~= Px([cast(int) e["r"].integer, cast(int) e["g"].integer,
                 cast(int) e["b"].integer, cast(int) e["a"].integer]);
    }
    assert(o.length == pts.length);
    return o;
}
private Px probe1(int[2] p) { return probe([p])[0]; }

private int maxDiff(Px a, Px b) {
    int m = 0;
    foreach (k; 0 .. 3) m = max(m, abs(a.c[k] - b.c[k]));
    return m;
}

private string hashCell() {
    auto j = getJson("/api/viewport/probe?cell=0&hash=1");
    assert("error" !in j && "hash" in j, "hash probe failed: " ~ j.toString);
    return j["hash"].toString;
}

/// Under values at `pts`: the pixels with the foreground layer ABSENT.
///
/// Not by hiding it: a hidden PRIMARY is still drawn by the foreground pass
/// (measured on this rig — `layer.setVisible 1 false` left every fill in
/// place), so the layer is moved out of the view through its item transform
/// instead, and moved back. Precondition and restore both read back.
private Px[] under(int[2][] pts) {
    double posX() {
        return num(getJson("/api/layers")["layers"].array[1]["xform"]["pos"].array[0]);
    }
    assert(posX() == 0.0, "under: layer 1 must start at pos.x 0");
    cmdOk("layer.attr 1 pos.x 1000");
    settle();
    assert(posX() == 1000.0, "under: the layer did not move out of the view");
    auto u = probe(pts);
    cmdOk("layer.attr 1 pos.x 0");
    settle();
    assert(posX() == 0.0, "under: the layer did not come back");
    return u;
}

// The specular term of our light at normal n, in LSB, gain g.
private double specLsb(double[3] n, double[3] eye, double[3] at, double g) {
    double[3] norm(double[3] v) {
        immutable l = sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
        return [v[0] / l, v[1] / l, v[2] / l];
    }
    immutable L = norm(kLightRaw);
    immutable V = norm([eye[0] - at[0], eye[1] - at[1], eye[2] - at[2]]);
    immutable H = norm([L[0] + V[0], L[1] + V[1], L[2] + V[2]]);
    immutable nh = max(0.0, n[0] * H[0] + n[1] * H[1] + n[2] * H[2]);
    return g * pow(nh, kSpecPow) * kSpecStr * 255.0;
}

/// The row (of three around the projected edge) that changed most between
/// two readings of the same column; the edge is rasterised on one of them.
private int[2][3] edgeRows(int[2] p) { return [[p[0], p[1] - 1], p, [p[0], p[1] + 1]]; }

private long edgeBetween(long a, long b) {
    auto edges = getJson("/api/model")["edges"].array;
    foreach (ei, e; edges) {
        immutable long p = e.array[0].integer, q = e.array[1].integer;
        if ((p == a && q == b) || (p == b && q == a)) return cast(long) ei;
    }
    assert(false, format("rig: no edge between vertices %d and %d", a, b));
}

private void selectEdges(const long[] idx) {
    string s = "[";
    foreach (i, v; idx) { if (i) s ~= ","; s ~= v.to!string; }
    cmdOk(commandBody("mesh.select", `{"mode":"edges","indices":` ~ s ~ `]}`));
    settle();
}

// ---------------------------------------------------------------------------
// The whole flow; each step names its cell. Cells that read the unmirrored
// rig come first, the in-place mirror (7b) last among the mode-on cells, the
// mode-off control after it.
// ---------------------------------------------------------------------------
unittest {
    auto r = buildRig();
    scope (exit) {
        cmdRaw(commandBody("viewport.retopology", `{"value":"off"}`));
        cmdRaw(commandBody("viewport.backdropStyle", `{"value":"same"}`));
        cmdRaw("viewport.view Perspective");
    }
    auto fg = r.fg;
    int[2] at(string n) { return toPx(fg[idxOf(fg, n)].c, r.vp); }
    int[2] atW(double[3] w) { return toPx(w, r.vp); }

    cmd("viewport.retopology", `{"value":"on"}`);
    {
        auto a = getJson("/api/viewport/display")["cells"].array[0]["plan"]["active"];
        assert(jb(a["clearDepthFirst"]) && jb(a["cullBackFaces"])
            && abs(num(a["faceAlpha"]) - 0.5) < 1e-6,
            "premise: the mode's plan must ask for the clear, the cull and alpha 0.5: "
            ~ a.toString);
    }

    // C's two probes: a quarter of the way in from its bottom (z = +0.1, in
    // front of P1) and from its top (z = -0.1, behind P1).
    immutable double[3] cLow = [fg[3].c[0], fg[3].c[1] - 0.5 * kH, 0.1];
    immutable double[3] cHigh = [fg[3].c[0], fg[3].c[1] + 0.5 * kH, -0.1];
    // Named probe points, read with the layer hidden and shown.
    int[2][] pts = [at("A"), at("B"), at("H"), atW(cLow), atW(cHigh), at("F"),
                    at("G"), at("D1"), at("D2"), at("S0"), at("Q")];
    enum { iA, iB, iH, iCl, iCh, iF, iG, iV1, iV2, iS, iQ }
    auto u = under(pts);
    auto o = probe(pts);
    writefln("  under %s", u);
    writefln("  on    %s", o);

    // ---- 1. B = A: identical inputs behind and in front of P1 --------------
    // One blend of the same fill over the same under value (P1, +Z, same gain)
    // gives the same integers; 1 LSB covers two different primitives' rounding.
    assert(maxDiff(o[iA], u[iA]) >= 5,
        format("1 premise: A over P1 reads its under value %s — no fill drawn", u[iA].c));
    assert(maxDiff(o[iB], o[iA]) <= 1,
        format("1: B (behind P1) reads %s and A (in front) %s — the item must start "
               ~ "on a cleared depth buffer", o[iB].c, o[iA].c));
    // ---- 2. H = A: 30 units behind — no depth offset ------------------------
    assert(maxDiff(o[iH], o[iA]) <= 1,
        format("2: H (z = -30) reads %s, A %s", o[iH].c, o[iA].c));
    // ---- 3. C's halves agree: one plane, one normal -------------------------
    assert(maxDiff(o[iCl], u[iCl]) >= 5, "3 premise: C's lower half has no fill");
    assert(maxDiff(o[iCh], o[iCl]) <= 1,
        format("3: C behind P1 reads %s, in front %s", o[iCh].c, o[iCl].c));

    // The fill's specular term moves with V = normalize(eye - p) even in the
    // orthographic view (our lit program's per-fragment V), so a +Z fill at
    // two places differs by S(p) - S(q), a few LSB on this rig: every cross-
    // position relation below carries that computed term, not a tolerance.
    double S(double[3] p) { return specLsb([0.0, 0.0, 1.0], r.eye, p, kGain); }

    // ---- 4. alpha: A over P1 and G over the empty viewport share the fill ---
    // outA - outG = a(cA - cG) + (1 - a)(uA - uG), cA - cG = S(A) - S(G):
    // a = 1 - (outA - outG - a(S(A) - S(G)))/(uA - uG), solved with a = 0.5 in
    // the (small) specular term. Four reads at +-0.5 give
    // |da| <= (1 + (1 - a))/|du| = 1.5/|du|. Floor: |du| >= 40 on two channels.
    {
        immutable double dS = S(fg[0].c) - S(fg[7].c);
        int wide = 0, checked = 0;
        foreach (k; 0 .. 3) {
            immutable double du = u[iA].c[k] - u[iG].c[k];
            if (abs(du) < 40) continue;
            ++wide;
            immutable double a = 1.0 - (o[iA].c[k] - o[iG].c[k] - 0.5 * dS) / du;
            immutable double tol = 1.5 / abs(du);
            assert(abs(a - 0.5) <= tol,
                format("4: channel %d solves alpha %.4f (tolerance %.4f around 0.5); "
                       ~ "outA %d outG %d uA %d uG %d dS %.2f", k, a, tol,
                       o[iA].c[k], o[iG].c[k], u[iA].c[k], u[iG].c[k], dS));
            ++checked;
        }
        assert(wide >= 2 && checked == wide,
            format("4 floor: P1 and the clear colour differ by >= 40 on only %d "
                   ~ "channels (%s vs %s)", wide, u[iA].c, u[iG].c));
    }
    // Destination alpha is left alone: G's fill blends colour only.
    assert(o[iG].c[3] == u[iG].c[3],
        format("4b: the fill wrote destination alpha (%d, under %d)",
               o[iG].c[3], u[iG].c[3]));

    // ---- 5. the lit arm: c = 2 outG - uG ------------------------------------
    // c carries 2*0.5 + 0.5 = 1.5 LSB. Prediction: the fill is the face colour
    // under the SAME light as P1 (a +Z material pass with the same gain):
    // P1 = base*K + S(A) at A's pixel, c = face*K + S(G), so
    // c = face/base * (P1 - S(A)) + S(G). Error: 1.5 + ratio*0.5 + 0.5.
    double[3] cG, cC;
    {
        immutable double ratio = kFace / r.base;
        immutable double tol = 1.5 + 0.5 * ratio + 0.5;
        foreach (k; 0 .. 3) {
            cG[k] = 2.0 * o[iG].c[k] - u[iG].c[k];
            immutable double pred = ratio * (u[iA].c[k] - S(fg[0].c)) + S(fg[7].c);
            assert(abs(cG[k] - pred) <= tol,
                format("5: channel %d fill %.1f, predicted %.2f = face/base x P1 %d "
                       ~ "(S(A) %.2f S(G) %.2f, tolerance %.2f)", k, cG[k], pred,
                       u[iA].c[k], S(fg[0].c), S(fg[7].c), tol));
            // The unlit rival: the flat 0.2 fill = 51.
            assert(abs(cG[k] - 51.0) >= 5,
                format("5 control: channel %d fill %.1f is the unlit 51", k, cG[k]));
            cC[k] = 2.0 * o[iCl].c[k] - u[iCl].c[k];
        }
        int m = 0;
        foreach (k; 0 .. 3) m = max(m, cast(int) abs(cC[k] - cG[k]));
        assert(m >= 3, format("5 control: C (tilted) fill %s equals G (+Z) %s — the "
                              ~ "fill ignores the normal", cC, cG));
        writefln("  5 fill c %s (P1 %s, S(G) %.3f); tilted %s", cG, u[iA].c,
                 S(fg[7].c), cC);
    }

    // ---- 6. within the item: REVERSE polygon order --------------------------
    // v1 (E1 back, created first): drawn AFTER D1, fails depth: single blend.
    // v2 (D2 front, created first): E2 drawn first, D2 over it: double blend.
    // Three-high stack created front first: drawn back-to-front, triple.
    // c at a place p is cG - S(G) + S(p). Errors: c carries 1.5 times its
    // weight, u 0.5 times its weight, and every blend in the chain rounds to
    // 8 bits (0.5, halved at each later blend): single 1.5, double 2.0,
    // triple 2.25.
    double cAt(int k, Quad q) { return cG[k] - S(fg[7].c) + S(q.c); }
    foreach (k; 0 .. 3) {
        immutable double p1 = 0.5 * cAt(k, fg[9]) + 0.5 * u[iV1].c[k];
        immutable double p2 = 0.5 * cAt(k, fg[10]) + 0.25 * cAt(k, fg[11])
                            + 0.25 * u[iV2].c[k];
        double p3 = u[iS].c[k];
        foreach (qi; [14, 13, 12]) p3 = 0.5 * cAt(k, fg[qi]) + 0.5 * p3;
        assert(abs(o[iV1].c[k] - p1) <= 0.5 * 1.5 + 0.5 * 0.5 + 0.5,
            format("6 v1: channel %d reads %d, predicted single %.2f (double %.2f)",
                   k, o[iV1].c[k], p1, 0.5 * p1 + 0.5 * cAt(k, fg[8])));
        assert(abs(o[iV2].c[k] - p2) <= 0.75 * 1.5 + 0.25 * 0.5 + 0.5 + 0.25,
            format("6 v2: channel %d reads %d, predicted double %.2f (single %.2f)",
                   k, o[iV2].c[k], p2, 0.5 * cAt(k, fg[10]) + 0.5 * u[iV2].c[k]));
        assert(abs(o[iS].c[k] - p3) <= 0.875 * 1.5 + 0.125 * 0.5 + 0.5 + 0.25 + 0.125,
            format("6 triple: channel %d reads %d, predicted %.2f", k, o[iS].c[k], p3));
    }
    // v1 and v2 must actually differ, or the pair separates nothing.
    assert(maxDiff(o[iV1], o[iV2]) >= 5,
        format("6: v1 %s and v2 %s do not separate the orders", o[iV1].c, o[iV2].c));
    // E1's edge under D1's fill: hidden (self-occlusion survives the clear).
    immutable double[3] e1Top = [fg[8].c[0], fg[8].c[1] + fg[8].half, fg[8].c[2]];
    {
        auto rows = probe(edgeRows(atW(e1Top)).dup);
        foreach (x; rows)
            assert(maxDiff(x, o[iV1]) <= 1,
                format("6: E1's edge leaks through D1's fill (%s vs the fill %s)",
                       x.c, o[iV1].c));
    }

    // ---- 7. back faces: F unfilled, the rest filled --------------------------
    assert(maxDiff(o[iF], u[iF]) <= 1,
        format("7: F (reversed) reads %s over its under %s — back faces are culled",
               o[iF].c, u[iF].c));
    {
        int n = 0;
        foreach (i; [iA, iB, iH, iCl, iCh, iG, iV1, iV2, iS]) {
            assert(maxDiff(o[i], u[i]) >= 5,
                format("7: probe %d reads its under value %s — a filled front face "
                       ~ "is missing (winding convention?)", i, u[i].c));
            ++n;
        }
        assert(n == 9, "7: population");
        immutable double[3] fEdge = [fg[4].c[0], fg[4].c[1] + kH, fg[4].c[2]];
        auto rowsOn = probe(edgeRows(atW(fEdge)).dup);
        auto rowsU = under(edgeRows(atW(fEdge)).dup);
        int best = 0;
        foreach (k; 0 .. 3) best = max(best, maxDiff(rowsOn[k], rowsU[k]));
        assert(best >= 5, "7: F's edges must still be drawn");
    }

    // ---- 8. C3: a culled polygon writes no depth ----------------------------
    // K's top edge runs behind F2 (reversed, in front). With no depth from F2
    // the edge is drawn over K's fill: it differs from a K pixel inside F2 that
    // carries no edge.
    {
        immutable double[3] kEdge = [fg[5].c[0], fg[5].c[1] + kH, fg[5].c[2]];
        immutable double[3] kIn = [fg[5].c[0] - 0.15, fg[5].c[1] + 0.2, fg[5].c[2]];
        auto rows = probe(edgeRows(atW(kEdge)).dup);
        immutable Px inside = probe1(atW(kIn));
        int best = 0;
        foreach (x; rows) best = max(best, maxDiff(x, inside));
        assert(best >= 5,
            format("8: K's edge behind F2 is hidden (rows %s, K fill %s) — the culled "
                   ~ "polygon wrote depth", rows, inside.c));
    }

    // ---- 10. selection over the cleared depth --------------------------------
    {
        immutable int vB = 4 * 1;   // B's first vertex: B is face 1
        immutable long eB = edgeBetween(vB + 2, vB + 3);   // B's top edge
        immutable int vE = 4 * 8;   // E1 is face 8
        immutable long eE = edgeBetween(vE + 2, vE + 3);   // E1's top edge
        immutable double[3] bTop = [fg[1].c[0], fg[1].c[1] + kH, fg[1].c[2]];
        auto bRows = edgeRows(atW(bTop)).dup;
        auto eRows = edgeRows(atW(e1Top)).dup;
        auto eBefore = probe(eRows);
        selectEdges([eB, eE]);
        parkPointer(r);
        auto bAfter = probe(bRows);
        auto eAfter = probe(eRows);
        // B's edge is behind P1 but in front of everything its own item wrote:
        // the full selection colour, one rounding: +-1.
        int bBest = 1000;
        foreach (x; bAfter) {
            int m = 0;
            foreach (k; 0 .. 3) m = max(m, abs(x.c[k] - kSel[k]));
            bBest = min(bBest, m);
        }
        assert(bBest <= 1,
            format("10: B's selected edge behind P1 reads %s, not the full %s",
                   bAfter, kSel));
        // E1's edge under D1's fill: the occluded pass, 0.3 sel + 0.7 below.
        // Errors 0.5 (sel rounding) + 0.7*0.5 + 0.5 = 1.35 -> 1.5.
        int row = -1, moved = 0;
        foreach (k; 0 .. 3) {
            immutable d = maxDiff(eAfter[k], eBefore[k]);
            if (d > moved) { moved = d; row = cast(int) k; }
        }
        assert(row >= 0 && moved >= 5, "10: E1's selected edge changed nothing");
        foreach (k; 0 .. 3) {
            immutable double pred = 0.30 * kSel[k] + 0.70 * eBefore[row].c[k];
            assert(abs(eAfter[row].c[k] - pred) <= 1.5,
                format("10: E1's edge under D1 channel %d reads %d, predicted the "
                       ~ "occluded 0.3 blend %.2f (full %d)", k, eAfter[row].c[k],
                       pred, kSel[k]));
        }
        selectEdges([]);
        cmdOk("select.typeFrom polygon");
        settle();
        parkPointer(r);
    }

    // ---- 11. the active style is irrelevant under the mode -------------------
    {
        immutable string hs = hashCell();
        cmd("viewport.displayStyle", `{"value":"wireframe"}`);
        immutable string hw = hashCell();
        cmd("viewport.displayStyle", `{"value":"shaded"}`);
        assert(hs == hw, format("11: wireframe %s vs shaded %s under the mode", hw, hs));
    }

    // ---- 9. perspective: facing per eye; B = A again -------------------------
    {
        immutable Px qOrtho = o[iQ];
        assert(maxDiff(qOrtho, u[iQ]) <= 1,
            format("9 ortho: Q is back-facing to the +Z eye and must be unfilled "
                   ~ "(%s over %s)", qOrtho.c, u[iQ].c));
        cmdOk("viewport.view Perspective");
        settle();
        auto cr = postJson("/api/camera?viewport=0",
            `{"azimuth":0.0,"elevation":0.0,"roll":0.0,"focus":{"x":0,"y":0,"z":0},"distance":10}`);
        assert(cr["status"].str == "ok", "camera: " ~ cr.toString);
        settle();
        auto vp = viewportFromCameraMatrices();
        assert(vp.proj[15] == 0.0f, "9: the cell must now be perspective");
        immutable double[3] eye = [vp.eye.x, vp.eye.y, vp.eye.z];
        immutable double s10 = sin(10.0 * PI / 180.0), c10 = cos(10.0 * PI / 180.0);
        immutable double[3] qc = fg[15].c;
        immutable double dPersp = c10 * (eye[0] - qc[0]) - s10 * (eye[2] - qc[2]);
        immutable double dOrtho = -s10;
        writefln("  9 eye %s: dot persp %.3f, ortho %.3f", eye, dPersp, dOrtho);
        assert(dPersp > 0.2 && dOrtho < 0,
            format("9 rig: the two eyes must disagree on Q's facing (persp %.3f, "
                   ~ "ortho %.3f)", dPersp, dOrtho));
        int[2][] pp = [toPx(qc, vp), toPx(fg[0].c, vp), toPx(fg[1].c, vp)];
        auto up = under(pp);
        auto op = probe(pp);
        assert(maxDiff(op[0], up[0]) >= 5,
            format("9 perspective: Q faces this eye and must be filled (%s over %s)",
                   op[0].c, up[0].c));
        // B = A in perspective. The two sit at different pixels, so P1 under
        // them and the fill's specular term move with V: bound the specular
        // difference and add it to the two roundings.
        immutable double dS = abs(specLsb([0.0, 0.0, 1.0], eye, fg[0].c, kGain)
                                - specLsb([0.0, 0.0, 1.0], eye, fg[1].c, kGain));
        assert(maxDiff(op[2], op[1]) <= 1 + 2 * dS + maxDiff(up[2], up[1]),
            format("9: in perspective B reads %s and A %s (unders %s %s)",
                   op[2].c, op[1].c, up[2].c, up[1].c));
        frontOrtho();
        parkPointer(r);
        auto back = probe([at("A")]);
        assert(maxDiff(back[0], o[iA]) <= 1, "9: the front ortho rig did not come back");
    }

    // ---- 7b. mirror the FOREGROUND layer in place (scl.x = -1) ---------------
    {
        // No transform tool may be armed (the scale channel is greyed under
        // one); the reset left none. Read the write back BEFORE any probe.
        cmdOk("layer.attr 1 scl.x -1");
        settle();
        auto xf = getJson("/api/layers")["layers"].array[1]["xform"];
        assert(num(xf["scl"].array[0]) == -1.0,
            "7b precondition: layer 1 scl.x must read back -1: " ~ xf.toString);
        assert(getJson("/api/layers")["active"].integer == 1,
            "7b: the mirrored layer must still be the primary");
        // Predictions, written before probing: the drawn normal of a face is
        // mat3(M) * n_local = (-nx, ny, nz); the orthographic eye is +Z, so a
        // face stays front-facing iff nz > 0 — the same set as unmirrored.
        string[] names = ["A", "B", "G", "C", "F", "Q"];
        bool[string] front = ["A": true, "B": true, "G": true, "C": true,
                              "F": false, "Q": false];
        int[2][] mp;
        foreach (n; names) {
            auto q = fg[idxOf(fg, n)];
            mp ~= toPx([-q.c[0], q.c[1], q.c[2]], r.vp);
        }
        auto mu = under(mp);
        auto mo = probe(mp);
        int filled = 0, culled = 0;
        foreach (i, n; names) {
            if (front[n]) {
                assert(maxDiff(mo[i], mu[i]) >= 5,
                    format("7b: mirrored %s faces the eye and must be filled (%s over %s)",
                           n, mo[i].c, mu[i].c));
                ++filled;
            } else {
                assert(maxDiff(mo[i], mu[i]) <= 1,
                    format("7b: mirrored %s faces away and must be culled (%s over %s)",
                           n, mo[i].c, mu[i].c));
                ++culled;
            }
        }
        assert(filled == 4 && culled == 2, "7b: population");
        cmdOk("layer.attr 1 scl.x 1");
        settle();
    }

    // ---- 12. mode off control: B is hidden behind P1 --------------------------
    cmd("viewport.retopology", `{"value":"off"}`);
    {
        auto uo = under([at("B")]);
        auto oo = probe([at("B")]);
        assert(maxDiff(oo[0], uo[0]) <= 1,
            format("12: with the mode off B (behind P1) reads %s, P1 %s", oo[0].c, uo[0].c));
    }
    writeln("  test_retopology_depth_fill: all cells passed");
}

// ---------------------------------------------------------------------------
// The lit program's face alpha is RESTORED after the scene's face pass: the
// pen's filled preview seeds its uniforms by hand, so it reads whatever the
// last face pass left. Its pixel — alpha included — must read the same with
// the mode on as off (same clicks, same rig).
// ---------------------------------------------------------------------------
private Px penPreviewPixel(bool modeOn) {
    auto r = buildRig();
    if (modeOn) cmd("viewport.retopology", `{"value":"on"}`);
    immutable int[2] c = toPx([0.9, -1.4, 0.0], r.vp);
    immutable int[2][3] tri = [[c[0] - 30, c[1] + 20], [c[0] + 30, c[1] + 20],
                               [c[0], c[1] - 30]];
    immutable int[2] centroid = [(tri[0][0] + tri[1][0] + tri[2][0]) / 3,
                                 (tri[0][1] + tri[1][1] + tri[2][1]) / 3];
    immutable Px emptyPx = probe1(centroid);
    cmdOk(`tool.set "pen" on 0`);
    string log = format(`{"t":0,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,`
        ~ `"fovY":0.785398}`, r.vp.x, r.vp.y, r.vp.width, r.vp.height) ~ "\n";
    double t = 100.0;
    foreach (w; tri) {
        immutable int x = w[0] + r.vp.x, y = w[1] + r.vp.y;
        log ~= format(`{"t":%g,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,`
                      ~ `"state":0,"mod":0}`, t, x, y) ~ "\n"
             ~ format(`{"t":%g,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,`
                      ~ `"clicks":1,"mod":0}`, t + 5, x, y) ~ "\n"
             ~ format(`{"t":%g,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,`
                      ~ `"clicks":1,"mod":0}`, t + 10, x, y) ~ "\n";
        t += 100.0;
    }
    auto pr = postJson("/api/play-events", log);
    assert(pr["status"].str == "success", "pen: /api/play-events failed: " ~ pr.toString);
    waitPlaybackProcessed();
    settle();
    auto px = probe1(centroid);
    assert(maxDiff(px, emptyPx) >= 3,
        format("pen premise: no preview fill was drawn (read %s, empty %s)",
               px.c, emptyPx.c));
    cmdRaw(`tool.set "pen" off 0`);
    cmdRaw(commandBody("viewport.retopology", `{"value":"off"}`));
    settle();
    return px;
}

unittest {
    immutable Px off = penPreviewPixel(false);
    immutable Px on  = penPreviewPixel(true);
    writefln("  pen preview rgba: mode off %s, mode on %s", off.c, on.c);
    foreach (k; 0 .. 4)
        assert(abs(on.c[k] - off.c[k]) <= 1,
            format("pen: the preview reads %s with the mode on and %s off — the face "
                   ~ "pass left its alpha (or blend) on the shared lit program",
                   on.c, off.c));
}
