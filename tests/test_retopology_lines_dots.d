// test_retopology_lines_dots.d — the base edges and vertex dots under the
// retopology display mode: colour, opacity and size from the plan, lit by the
// item's light function at its local +Z, and the per-eye cull of the dots.
//
// Rig: OPEN quads only, two layers. Layer 0 (background, `flat` backdrop) is
// P1, a big +Z quad, and P2, a quad tilted toward +Y; they give three
// different "under" values with the empty view. Layer 1 (the primary) carries
// every probed element; its FIRST vertex, I0, is its only isolated one (the
// free dot, hidden in cell 4a). Edges are read on REVERSED quads, which the
// mode leaves unfilled, so an edge pixel blends straight over the backdrop.
// A dot is "present" when its pixel changes with `viewport.showVertices`.
//
// TOLERANCES come from 8-bit quantisation: every read value is +-0.5 LSB and
// each derived quantity carries its propagated error, stated beside it.
module test_retopology_lines_dots;

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

// Our light rig (source/light_rig.d, task 9130: eye-space key and fill, global
// ambient) and the mode's constants — the relation under test is "lit by OUR
// light function at the item's local +Z". The Retopology arm and its line
// mirror carry no specular term.
private enum double kAmbient = 0.15, kKeyI = 0.7, kFillI = 0.3;
private immutable double[3] kKeyEye = [-0.654509, 0.587785, 0.475528];
private immutable double[3] kFillEye = [1.0, 0.0, 0.0];
private enum double kGain = 5.0 / 3.0;
private enum double kLineAlpha = 0.4;
private immutable double[3] kEdgePal = [0.11, 0.25, 0.41];
private immutable double[3] kVertPal = [0.38, 0.62, 0.92];
private enum double kFacePal = 0.2;
private immutable int[3] kSel = [255, 168, 41];

private void settle() { quiesce(); frameFence(null, 2); }
private JSONValue cmdRaw(string body) { return postJson("/api/command", body); }
private void cmdOk(string body) {
    auto r = cmdRaw(body);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "command failed: " ~ body ~ " -> " ~ r.toString);
}
private void cmd(string id, string params) { cmdOk(commandBody(id, params)); settle(); }

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
// Our light function (the lit program's `litTerm`), in doubles
// ---------------------------------------------------------------------------
private double[3] nrm(double[3] v) {
    immutable l = sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    return [v[0] / l, v[1] / l, v[2] / l];
}
private double dot3(double[3] a, double[3] b) { return a[0]*b[0] + a[1]*b[1] + a[2]*b[2]; }

/// The light factor (0..) at WORLD normal `n` seen through `vp`: the normal
/// is taken to eye space by the view's rotation (the rig turns with the camera).
private double lightAt(double[3] n, const ref Viewport vp) {
    immutable N = nrm([vp.view[0]*n[0] + vp.view[4]*n[1] + vp.view[8]*n[2],
                       vp.view[1]*n[0] + vp.view[5]*n[1] + vp.view[9]*n[2],
                       vp.view[2]*n[0] + vp.view[6]*n[1] + vp.view[10]*n[2]]);
    immutable dif = kKeyI * max(0.0, dot3(N, kKeyEye)) + kFillI * max(0.0, dot3(N, kFillEye));
    return kAmbient + kGain * dif;
}

/// 255 x the shaded palette colour, channel `c`.
private double shaded(const double[3] pal, int c, double[3] n, const ref Viewport vp) {
    return 255.0 * pal[c] * lightAt(n, vp);
}

// ---------------------------------------------------------------------------
// Rig geometry
// ---------------------------------------------------------------------------
private struct Quad {
    string    name;
    double[3] c;
    double    half;
    double    tiltX;     // rotation about X through the centre, degrees
    bool      reversed;
}

private double[3][4] corners(Quad q) {
    immutable double[2][4] xy = [[-q.half, -q.half], [q.half, -q.half],
                                 [q.half, q.half], [-q.half, q.half]];
    immutable double ct = cos(q.tiltX * PI / 180), st = sin(q.tiltX * PI / 180);
    double[3][4] o;
    foreach (k; 0 .. 4)
        o[k] = [q.c[0] + xy[k][0], q.c[1] + xy[k][1] * ct, q.c[2] + xy[k][1] * st];
    return o;
}

private Quad flat(string n, double x, double y, double z, double half, bool rev = false) {
    return Quad(n, [x, y, z], half, 0, rev);
}

private immutable Quad kP1 = Quad("P1", [-2.0, 1.0, 0.0], 1.0, 0, false);
// P2: tilted -26.6 degrees about X (normal (0, 0.447, 0.894)): a second lit
// value under an edge.
private immutable Quad kP2 = Quad("P2", [0.6, 1.2, 0.0], 0.5, -26.565, false);

// The foreground: EA / EB / EG, reversed (unfilled) edge probes over P1, P2
// and the empty view; five reversed tiles T tilted -60..60 about X; G, a
// front quad; F, a reversed quad sharing G's corner (0.1, -0.9); E under D;
// Q, the oblique quad of the perspective cell (built in `fgJson`).
private Quad[] fgQuads() {
    // G FIRST: vertices 2..5, so the vertex after the hidden I0 and I0 is a
    // drawn dot (cell 4a), and F's own corners follow G's last vertex.
    Quad[] qs = [
        flat("G", -0.2, -0.6, 0.0, 0.3),
        flat("EA", -2.4, 1.4, 0.5, 0.3, true),
        flat("EB", 0.6, 1.2, 1.0, 0.3, true),
        flat("EG", 2.2, 1.2, 0.5, 0.3, true),
    ];
    foreach (i, t; [-60.0, -30.0, 0.0, 30.0, 60.0])
        qs ~= Quad(format("T%d", i), [0.4 + 0.6 * i, 0.2, 0.0], 0.2, t, true);
    qs ~= flat("E", -2.4, -1.0, 0.0, 0.2);
    qs ~= flat("D", -2.2, -0.8, 0.5, 0.4);
    return qs;
}

// Vertex indices the cells name (fixed by `fgJson`'s build order).
private enum int kI0 = 0;
private immutable double[3] kI0Pos = [2.2, -1.4, 0.0];
// F's three own corners and the corner it shares with G.
private immutable double[3] kShared = [0.1, -0.9, 0.0];
private immutable double[3][3] kFOwn = [[0.7, -0.9, 0.0], [0.7, -1.5, 0.0],
                                        [0.1, -1.5, 0.0]];
// Q: normal (cos10, 0, -sin10) — back to the +Z orthographic eye, front to a
// perspective eye at (0, 0, 10).
private immutable double[3] kQc = [-3.3, -0.4, 0.0];
private enum double kQh = 0.25;

private double[3][4] qCorners() {
    immutable double s10 = sin(10.0 * PI / 180.0), c10 = cos(10.0 * PI / 180.0);
    immutable double[2][4] uv = [[-1, -1], [1, -1], [1, 1], [-1, 1]];
    double[3][4] o;
    foreach (k; 0 .. 4)
        o[k] = [kQc[0] + uv[k][0] * kQh * s10, kQc[1] + uv[k][1] * kQh,
                kQc[2] + uv[k][0] * kQh * c10];
    return o;
}

private struct Fg {
    Quad[] qs;
    JSONValue json;
    int gCorner;      // vertex index of the shared corner
    int[3] fOwn;      // vertex indices of F's own corners
    int[4] q;         // Q's corners
    int eCorner;      // E's top-right corner, under D's fill
}

private Fg fgJson() {
    Fg f;
    f.qs = fgQuads();
    JSONValue[] verts, faces;
    int add(double[3] p) {
        verts ~= JSONValue([p[0], p[1], p[2]]);
        return cast(int)(verts.length - 1);
    }
    assert(add(kI0Pos) == kI0);
    foreach (q; f.qs) {
        auto cs = corners(q);
        long[] fc;
        foreach (p; cs) fc ~= add(p);
        if (q.reversed) fc = [fc[3], fc[2], fc[1], fc[0]];
        faces ~= JSONValue(fc);
        if (q.name == "G") {
            // G's corner order is (-,-), (+,-), (+,+), (-,+): the shared
            // corner (0.1, -0.9) is its SECOND.
            f.gCorner = cast(int) fc[1];
            // F right after G: its own corners follow G's last vertex, so a
            // slot error of one shows an F corner.
            foreach (k; 0 .. 3) f.fOwn[k] = add(kFOwn[k]);
            // (0.1,-0.9) -> (0.7,-0.9) -> (0.7,-1.5) -> (0.1,-1.5): clockwise.
            faces ~= JSONValue([cast(long) f.gCorner, f.fOwn[0], f.fOwn[1], f.fOwn[2]]);
        }
        if (q.name == "E") f.eCorner = cast(int) fc[2];
    }
    auto qc = qCorners();
    long[] qf;
    foreach (k; 0 .. 4) { f.q[k] = add(qc[k]); qf ~= f.q[k]; }
    faces ~= JSONValue([qf[3], qf[2], qf[1], qf[0]]);
    f.json = JSONValue(["vertices": JSONValue(verts), "faces": JSONValue(faces)]);
    return f;
}

private JSONValue bgJson() {
    JSONValue[] verts, faces;
    foreach (q; [cast(Quad) kP1, cast(Quad) kP2]) {
        long[] fc;
        foreach (p; corners(q)) {
            verts ~= JSONValue([p[0], p[1], p[2]]);
            fc ~= cast(long)(verts.length - 1);
        }
        faces ~= JSONValue(fc);
    }
    return JSONValue(["vertices": JSONValue(verts), "faces": JSONValue(faces)]);
}

private int idxOf(Quad[] qs, string n) {
    foreach (i, q; qs) if (q.name == n) return cast(int) i;
    assert(false, "rig: no quad " ~ n);
}

private struct Rig {
    Fg       fg;
    Viewport vp;
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

private void readCamera(ref Rig r) {
    r.vp = viewportFromCameraMatrices();
    r.eye = [r.vp.eye.x, r.vp.eye.y, r.vp.eye.z];
}

private Rig buildRig() {
    cmdOk(commandBody("scene.reset"));
    cmdOk(`{"id":"history.clear"}`);
    cmdOk(commandBody("viewport.layout", `"Single"`));
    cmdOk(commandBody("scene.loadMesh", bgJson().toString));
    cmdOk(`{"id":"layer.add"}`);
    Rig r;
    r.fg = fgJson();
    cmdOk(commandBody("scene.loadMesh", r.fg.json.toString));
    frontOrtho();
    cmd("viewport.displayStyle", `{"value":"shaded"}`);
    cmd("viewport.backdropStyle", `{"value":"flat"}`);
    cmdOk("select.typeFrom polygon");
    settle();

    auto L = getJson("/api/layers");
    assert(L["layers"].array.length == 2 && L["active"].integer == 1,
        "rig: expected two layers with layer 1 the primary: " ~ L.toString);
    auto M = getJson("/api/model");
    assert(M["vertices"].array.length == r.fg.json["vertices"].array.length
        && M["faces"].array.length == r.fg.json["faces"].array.length,
        format("rig: layer 1 has %s vertices / %s faces, built %s / %s",
               M["vertices"].array.length, M["faces"].array.length,
               r.fg.json["vertices"].array.length, r.fg.json["faces"].array.length));
    readCamera(r);
    assert(r.vp.proj[15] != 0.0f, "rig: the Front view must be orthographic");
    assert(r.eye[2] > 1.0 && abs(r.eye[0]) < 0.01 && abs(r.eye[1]) < 0.01,
        format("rig: the eye must sit on +Z, got %s", r.eye));
    double[3][] probes = [kI0Pos, kShared, kQc];
    foreach (q; r.fg.qs) probes ~= q.c;
    foreach (p; probes) {
        auto px = toPx(p, r.vp);
        assert(px[0] > 20 && px[1] > 20 && px[0] < r.vp.width - 20 && px[1] < r.vp.height - 20,
            format("rig: point %s projects to %s, outside the %sx%s cell",
                   p, px, r.vp.width, r.vp.height));
    }
    auto e0 = toPx([0.0, 0.0, 0.0], r.vp), e1 = toPx([0.2, 0.0, 0.0], r.vp);
    assert(abs(e1[0] - e0[0]) >= 8,
        format("rig: 0.2 units is only %s px", abs(e1[0] - e0[0])));
    parkPointer(r);
    return r;
}

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
private struct Px { int[4] c; }

private Px[] probe(int[2][] pts) {
    Px[] o;
    for (size_t at = 0; at < pts.length; at += 120) {
        string q = "/api/viewport/probe?cell=0&points=";
        foreach (k, p; pts[at .. min(at + 120, pts.length)])
            q ~= format("%s%d,%d", k ? ";" : "", p[0], p[1]);
        auto j = getJson(q);
        assert("error" !in j, "probe failed: " ~ j.toString);
        assert(jb(j["renders"]), "the probed cell is not rendered; every reading is void");
        foreach (e; j["points"].array) {
            assert("error" !in e, "probe point unreadable: " ~ e.toString);
            o ~= Px([cast(int) e["r"].integer, cast(int) e["g"].integer,
                     cast(int) e["b"].integer, cast(int) e["a"].integer]);
        }
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

/// Pixels of the square window of half-size `h` around `p`.
private int[2][] window(int[2] p, int h) {
    int[2][] o;
    foreach (dy; -h .. h + 1)
        foreach (dx; -h .. h + 1) o ~= [p[0] + dx, p[1] + dy];
    return o;
}

private void showVertices(bool on) {
    cmd("viewport.showVertices", on ? `{"value":"on"}` : `{"value":"off"}`);
}

/// Pixels a 3 px dot at a polygon CORNER changes: the base dot pass is
/// depth-tested and the corner's own edges, drawn first at the same depth,
/// keep their pixels (measured: the middle row and column), so four of the
/// nine remain. A free vertex changes all nine.
private enum int kCornerDot = 4;

/// How many pixels of each window change between vertex dots off and on.
private int[] dotPixels(int[2][] centres, int h) {
    int[2][] pts;
    foreach (c; centres) pts ~= window(c, h);
    showVertices(false);
    auto off = probe(pts);
    showVertices(true);
    auto on = probe(pts);
    immutable size_t w = (2 * h + 1) * (2 * h + 1);
    int[] n = new int[](centres.length);
    foreach (i; 0 .. pts.length)
        if (maxDiff(on[i], off[i]) >= 3) ++n[i / w];
    return n;
}

/// Under values at `pts`: the pixels with the foreground layer moved away
/// (a hidden primary is still drawn, backlog 8559).
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

/// The row of three around an edge pixel that differs most from `u`.
private int edgeRow(Px[3] o, Px[3] u) {
    int best = 0;
    foreach (i; 1 .. 3) if (maxDiff(o[i], u[i]) > maxDiff(o[best], u[best])) best = i;
    return best;
}

/// The unblended edge colour (out - 0.6 u) / 0.4 at the bottom edge of quad
/// `q` (world corners `cs`), and the under value there. Error: 2.0 LSB.
private double[3] edgeColour(double[3][4] cs, ref Viewport vp, out Px uOut,
                             out Px oOut) {
    immutable double[3] mid = [(cs[0][0] + cs[1][0]) / 2, (cs[0][1] + cs[1][1]) / 2,
                               (cs[0][2] + cs[1][2]) / 2];
    auto p = toPx(mid, vp);
    int[2][] rows = [[p[0], p[1] - 1], [p[0], p[1]], [p[0], p[1] + 1]];
    auto u = under(rows);
    auto o = probe(rows);
    immutable int k = edgeRow([o[0], o[1], o[2]], [u[0], u[1], u[2]]);
    assert(maxDiff(o[k], u[k]) >= 3,
        format("edge premise: no edge drawn at %s (%s over %s)", rows[k], o[k].c, u[k].c));
    uOut = u[k];
    oOut = o[k];
    double[3] e;
    foreach (c; 0 .. 3) e[c] = (o[k].c[c] - 0.6 * u[k].c[c]) / kLineAlpha;
    return e;
}

private JSONValue cellJson(int k) {
    return getJson("/api/viewport/display")["cells"].array[k];
}
private long recomputes(int k) { return cellJson(k)["dotCullRecomputes"].integer; }

private void selectVerts(int[] idx) {
    string s = "[";
    foreach (i, v; idx) { if (i) s ~= ","; s ~= v.to!string; }
    cmdOk(commandBody("mesh.select", `{"mode":"vertices","indices":` ~ s ~ `]}`));
    settle();
}

// ---------------------------------------------------------------------------
// The flow. Mode-on cells first, the mirror last among them, the mode-off
// control at the end.
// ---------------------------------------------------------------------------
unittest {
    auto r = buildRig();
    scope (exit) {
        cmdRaw("tool.set xfrm.elementMove off");
        cmdRaw(commandBody("viewport.retopology", `{"value":"off"}`));
        cmdRaw(commandBody("viewport.showVertices", `{"value":"off"}`));
        cmdRaw(commandBody("viewport.pointSize", `{"value":0}`));
        cmdRaw(commandBody("viewport.backdropStyle", `{"value":"same"}`));
        cmdRaw(commandBody("viewport.layout", `"Single"`));
        cmdRaw("viewport.view Perspective");
    }
    auto qs = r.fg.qs;
    double[3][4] cq(string n) { return corners(qs[idxOf(qs, n)]); }
    int[2] px(double[3] w) { return toPx(w, r.vp); }
    int[2] vpx(int vi) {
        auto v = getJson("/api/model")["vertices"].array[vi].array;
        return px([num(v[0]), num(v[1]), num(v[2])]);
    }

    cmd("viewport.retopology", `{"value":"on"}`);
    {
        auto a = cellJson(0)["plan"]["active"];
        assert(jb(a["shadeLinesByItem"]) && jb(a["cullHiddenVerts"])
            && !jb(a["baseDotsBySelection"]) && abs(num(a["wireAlpha"]) - 0.4) < 1e-6
            && abs(num(a["vertAlpha"]) - 0.4) < 1e-6,
            "premise: the mode's plan must shade lines per item, cull dots and "
            ~ "draw them at 0.4: " ~ a.toString);
    }
    immutable double[3] zN = [0.0, 0.0, 1.0], origin = [0.0, 0.0, 0.0];

    // ---- 1. edge blend identity over three backdrop values ----------------
    // out = 0.4 c + 0.6 u, c = 255 lineShade(edge palette, identity, eye).
    // out +-0.5, u +-0.5 x 0.6, c is not integral: +-0.5 => |out - pred| <= 1.3.
    double[3][string] e0;
    {
        int n = 0;
        foreach (name; ["EA", "EB", "EG"]) {
            Px u, o;
            e0[name] = edgeColour(cq(name), r.vp, u, o);
            foreach (c; 0 .. 3) {
                immutable double cc = shaded(kEdgePal, c, zN, r.vp);
                immutable double pred = kLineAlpha * cc + (1 - kLineAlpha) * u.c[c];
                assert(abs(o.c[c] - pred) <= 1.3,
                    format("1: %s edge channel %d reads %d over %d, predicted %.2f "
                           ~ "(lit palette %.2f)", name, c, o.c[c], u.c[c], pred, cc));
            }
            ++n;
        }
        assert(n == 3, "1 floor");
    }

    // ---- 2a. tilted tiles' edges equal flat ones: not the polygon normal ----
    // Unblended over the same empty view: each e carries 2.0 LSB, so two
    // agree within 4.0.
    {
        int n = 0;
        foreach (i; 0 .. 5) {
            Px u, o;
            auto e = edgeColour(cq(format("T%d", i)), r.vp, u, o);
            foreach (c; 0 .. 3)
                assert(abs(e[c] - e0["EG"][c]) <= 4.0,
                    format("2a: tile T%d (tilt %s) edge channel %d unblends to %.1f, "
                           ~ "the flat EG edge to %.1f", i, -60 + 30 * i, c, e[c],
                           e0["EG"][c]));
            ++n;
        }
        assert(n == 5, "2a floor");
    }

    // ---- 3. dots: colour, opacity, size; the selected size follows ----------
    {
        immutable int[2] ip = px(kI0Pos);
        auto n3 = dotPixels([ip], 4)[0];
        assert(n3 >= 9 && n3 <= 16,
            format("3: a 3 px dot changed %s pixels, expected 9 (at most 16 off-centre)", n3));
        // The dot's centre: out = 0.4 c + 0.6 u (u with the dots off), +-1.3.
        showVertices(false);
        immutable Px u = probe1(ip);
        showVertices(true);
        immutable Px o = probe1(ip);
        foreach (c; 0 .. 3) {
            immutable double cc = shaded(kVertPal, c, zN, r.vp);
            immutable double pred = kLineAlpha * cc + (1 - kLineAlpha) * u.c[c];
            assert(abs(o.c[c] - pred) <= 1.3,
                format("3: I0's dot channel %d reads %d over %d, predicted %.2f", c,
                       o.c[c], u.c[c], pred));
        }
        cmd("viewport.pointSize", `{"value":6}`);
        auto n6 = dotPixels([ip], 6)[0];
        assert(n6 >= 36 && n6 <= 49,
            format("3: a 6 px dot changed %s pixels, expected 36..49", n6));
        // Selected: the highlight size is twice the BASE size, 12.
        cmdOk("select.typeFrom vertex");
        selectVerts([kI0]);
        auto w = window(ip, 9);
        auto sel = probe(w);
        cmdOk("select.typeFrom polygon");
        selectVerts([]);
        auto none = probe(w);
        int ns = 0;
        foreach (i; 0 .. w.length) if (maxDiff(sel[i], none[i]) >= 3) ++ns;
        assert(ns >= 144 && ns <= 169,
            format("3: the selected dot of a 6 px cell covers %s pixels, expected "
                   ~ "12 px (144..169)", ns));
        cmd("viewport.pointSize", `{"value":0}`);
    }

    // ---- 4. cull: F's own corners absent; I0 and the shared corner present --
    showVertices(true);
    {
        int[2][] cs = [px(kFOwn[0]), px(kFOwn[1]), px(kFOwn[2]), px(kI0Pos), px(kShared)];
        auto n = dotPixels(cs, 2);
        foreach (k; 0 .. 3)
            assert(n[k] == 0, format("4: F's corner %s draws a dot (%s px) — every "
                ~ "polygon around it faces away", kFOwn[k], n[k]));
        assert(n[3] >= 9, format("4: the isolated vertex I0 lost its dot (%s px)", n[3]));
        assert(n[4] >= kCornerDot, format("4: the corner F shares with front-facing G lost its "
            ~ "dot (%s px)", n[4]));
        // A SELECTED vertex of F is drawn (highlight pass), culled base or not.
        cmdOk("select.typeFrom vertex");
        settle();
        auto before = probe(window(cs[0], 2));
        selectVerts([r.fg.fOwn[0]]);
        auto after = probe(window(cs[0], 2));
        int m = 0;
        foreach (i; 0 .. before.length) if (maxDiff(before[i], after[i]) >= 3) ++m;
        assert(m >= 9, format("4: F's selected corner is not drawn (%s px)", m));
        selectVerts([]);
        cmdOk("select.typeFrom polygon");
        settle();
    }

    // ---- 4a. the list is in compacted VBO slots ----------------------------
    // Hide I0, the isolated vertex created FIRST (hiding a face corner would
    // take its faces along and move four slots). A list in mesh indices would
    // be off by one from here on: I0's dot (slot 0) goes, and G's last vertex
    // (kept) would light F's first own corner.
    {
        cmdOk("select.typeFrom vertex");
        // No command hides a loose point directly (mesh.hide acts on faces):
        // hide every face, then flip the VERTEX plane — the face-bound
        // vertices come back, the one loose point becomes hidden, and no face
        // touches it.
        selectVerts([]);
        cmdOk(commandBody("mesh.hide"));
        cmdOk(commandBody("mesh.hideInvert"));
        settle();
        auto M = getJson("/api/model");
        int hv = 0, hf = 0;
        foreach (b; M["vertexHidden"].array) if (jb(b)) ++hv;
        foreach (b; M["faceHidden"].array) if (jb(b)) ++hf;
        assert(hv == 1 && hf == 0 && jb(M["vertexHidden"].array[kI0]),
            format("4a premise: expected exactly I0 hidden and no face, got %s "
                   ~ "vertices / %s faces", hv, hf));
        cmdOk("select.typeFrom polygon");
        selectVerts([]);
        int[2][] cs = [px(kFOwn[0]), px(kFOwn[1]), px(kFOwn[2]), vpx(1),
                       vpx(2), px(kI0Pos)];
        auto n = dotPixels(cs, 2);
        foreach (k; 0 .. 3)
            assert(n[k] == 0, format("4a: F's corner %s lit up (%s px) after a "
                ~ "lower vertex was hidden — the list is not in VBO slots", kFOwn[k], n[k]));
        assert(n[3] >= kCornerDot && n[4] >= kCornerDot,
            format("4a: the two vertices after the hidden one lost their dots "
                   ~ "(%s, %s px)", n[3], n[4]));
        assert(n[5] == 0, format("4a: the hidden vertex draws a dot (%s px)", n[5]));
        cmdOk(commandBody("mesh.unhideAll"));
        settle();
    }

    // ---- 5. self-occlusion: E's corner under D's fill has no dot ------------
    {
        auto n = dotPixels([vpx(r.fg.eCorner)], 2);
        assert(n[0] == 0, format("5: E's corner under D's fill draws a dot (%s px)", n[0]));
    }

    // ---- 5c. selection modes: the base dots follow showVertices only --------
    {
        auto w = window(px(kI0Pos), 3);
        string[] modes = ["vertex", "edge", "polygon"];
        showVertices(false);
        cmdOk("select.typeFrom polygon");
        settle();
        auto none = probe(w.dup);
        int rows = 0;
        foreach (md; modes) {
            cmdOk("select.typeFrom " ~ md);
            settle();
            auto got = probe(w.dup);
            foreach (i; 0 .. w.length)
                assert(maxDiff(got[i], none[i]) <= 1,
                    format("5c: with vertex dots off, %s mode draws a base dot at I0 "
                           ~ "(%s vs %s)", md, got[i].c, none[i].c));
            ++rows;
        }
        assert(rows == 3, "5c floor");
        showVertices(true);
        Px[][] on;
        foreach (md; modes) {
            cmdOk("select.typeFrom " ~ md);
            settle();
            on ~= probe(w.dup);
        }
        foreach (m; 1 .. 3)
            foreach (i; 0 .. w.length)
                assert(on[m][i].c == on[0][i].c,
                    format("5c: the dot at I0 differs between %s and %s mode", modes[0],
                           modes[m]));
        int lit = 0;
        foreach (i; 0 .. w.length) if (maxDiff(on[0][i], none[i]) >= 3) ++lit;
        assert(lit >= 9, format("5c premise: the on-reading has no dot (%s px)", lit));
        cmdOk("select.typeFrom polygon");
        settle();
    }

    // ---- 2b. an ITEM rotation of +40 degrees about Y moves the edge colour --
    // Predicted from the fill of the rotated G (a +Z polygon of the same item)
    // over the empty view: f = 2 out - u (1.5 LSB), and the edge from the
    // palette ratio: e = ratio f (no specular term in either, task 9130).
    // Tolerance: 2.0 (edge) + ratio 1.5 (fill).
    {
        cmdOk("layer.attr 1 rot.y 40");
        settle();
        assert(num(getJson("/api/layers")["layers"].array[1]["xform"]["rot"].array[1]) == 40.0,
            "2b precondition: layer 1 rot.y must read back 40");
        immutable double c40 = cos(40 * PI / 180), s40 = sin(40 * PI / 180);
        double[3] ry(double[3] p) {
            return [p[0] * c40 + p[2] * s40, p[1], -p[0] * s40 + p[2] * c40];
        }
        double[3][4] rc(string n) {
            auto c = cq(n);
            foreach (ref p; c) p = ry(p);
            return c;
        }
        Px u, o;
        auto e = edgeColour(rc("EG"), r.vp, u, o);
        immutable double[3] gc = ry(qs[idxOf(qs, "G")].c);
        auto gp = px(gc);
        auto gu = under([gp])[0];
        auto go = probe1(gp);
        foreach (c; 0 .. 3) {
            immutable double f = 2.0 * go.c[c] - gu.c[c];
            immutable double ratio = kEdgePal[c] / kFacePal;
            immutable double pred = ratio * f;
            immutable double tol = 2.0 + ratio * 1.5;
            assert(abs(e[c] - pred) <= tol,
                format("2b: the rotated item's edge channel %d unblends to %.1f, "
                       ~ "predicted %.1f from its +Z fill %.1f (tolerance %.1f)",
                       c, e[c], pred, f, tol));
            if (c == 2)
                assert(abs(e0["EG"][c] - pred) > 2 * tol,
                    format("2b rig: the unrotated edge %.1f is within %.1f of the "
                           ~ "rotated prediction %.1f — the cell cannot discriminate",
                           e0["EG"][c], 2 * tol, pred));
        }
        cmdOk("layer.attr 1 rot.y 0");
        settle();
    }

    // ---- 2c. rotating the CAMERA moves our edge colour (view-relative rig) --
    // The rig is eye space (task 9130; the reference's is camera-attached too,
    // fixture `light_rig`), so a 40° orbit turns the fixed item's +Z normal in
    // eye space: the unblended edge (2.0 LSB) equals the light function at
    // the NEW view, +-2.5. Floor first: that prediction is > 2 x 2.5 from the
    // front-view edge on channel 2, so an unchanged colour (a world-fixed
    // rig) fails the cell. A preset orthographic view keeps its axis, so the
    // orbit (azimuth in RADIANS) is a perspective camera, which EG (reversed,
    // unfilled) still faces away from.
    {
        cmdOk("viewport.view Perspective");
        settle();
        auto cr = postJson("/api/camera?viewport=0",
            `{"azimuth":0.6981317,"elevation":0.0,"roll":0.0,"focus":{"x":0,"y":0,"z":0},"distance":9}`);
        assert(cr["status"].str == "ok", "2c camera: " ~ cr.toString);
        settle();
        Rig r2 = r;
        readCamera(r2);
        parkPointer(r2);
        double[3] eyeDir = nrm(r2.eye.dup[0 .. 3]);
        assert(abs(eyeDir[2] - cos(40 * PI / 180)) < 0.02,
            format("2c premise: the eye is not at 40 degrees (%s)", r2.eye));
        immutable double moved = abs(shaded(kEdgePal, 2, zN, r2.vp) - e0["EG"][2]);
        assert(moved > 2 * 2.5, format("2c floor: the view-relative prediction moves "
            ~ "channel 2 by only %.2f from the front-view edge %.1f", moved, e0["EG"][2]));
        Px u, o;
        auto e = edgeColour(cq("EG"), r2.vp, u, o);
        foreach (c; 0 .. 3) {
            immutable double pred = shaded(kEdgePal, c, zN, r2.vp);
            assert(abs(e[c] - pred) <= 2.5,
                format("2c: after a camera rotation the edge channel %d unblends to "
                       ~ "%.1f, predicted %.2f at the new view (%.1f before) — the light "
                       ~ "must turn with the camera", c, e[c], pred, e0["EG"][c]));
        }
        writefln("  2c edge after the orbit %s, front view %s", e, e0["EG"]);
        // The base DOTS turn with it too (their own call site): I0's dot,
        // out = 0.4 c + 0.6 u, +-1.3 as in cell 3, c at the NEW view. Floor:
        // 0.4 x the move of c on channel 2 exceeds 2 x 1.3.
        {
            immutable int[2] ip = toPx(kI0Pos, r2.vp);
            immutable double cFront = shaded(kVertPal, 2, zN, r.vp);
            immutable double cOrbit = shaded(kVertPal, 2, zN, r2.vp);
            assert(0.4 * abs((cOrbit > 255 ? 255 : cOrbit) - cFront) > 2 * 1.3,
                format("2c floor: the dot prediction moves only %.2f -> %.2f", cFront, cOrbit));
            showVertices(false);
            immutable Px du = probe1(ip);
            showVertices(true);
            immutable Px dot = probe1(ip);
            foreach (c; 0 .. 3) {
                double cc = shaded(kVertPal, c, zN, r2.vp);
                if (cc > 255) cc = 255;
                immutable double pred = kLineAlpha * cc + (1 - kLineAlpha) * du.c[c];
                assert(abs(dot.c[c] - pred) <= 1.3,
                    format("2c: after a camera rotation I0's dot channel %d reads %d over %d, "
                           ~ "predicted %.2f at the new view — the dots' light must turn "
                           ~ "with the camera", c, dot.c[c], du.c[c], pred));
            }
            writefln("  2c dot after the orbit %s over %s", dot.c, du.c);
        }
        frontOrtho();
        parkPointer(r);
    }

    // ---- 5b. perspective: Q's corners follow the eye ------------------------
    {
        int[2][] qo;
        foreach (k; 0 .. 4) qo ~= vpx(r.fg.q[k]);
        auto no = dotPixels(qo, 2);
        foreach (k; 0 .. 4)
            assert(no[k] == 0, format("5b ortho: Q faces away from the +Z eye; its "
                ~ "corner %d draws a dot (%s px)", k, no[k]));
        cmdOk("viewport.view Perspective");
        settle();
        auto cr = postJson("/api/camera?viewport=0",
            `{"azimuth":0.0,"elevation":0.0,"roll":0.0,"focus":{"x":0,"y":0,"z":0},"distance":10}`);
        assert(cr["status"].str == "ok", "5b camera: " ~ cr.toString);
        settle();
        Rig rp = r;
        readCamera(rp);
        assert(rp.vp.proj[15] == 0.0f, "5b: the cell must now be perspective");
        parkPointer(rp);
        immutable double s10 = sin(10.0 * PI / 180.0), c10 = cos(10.0 * PI / 180.0);
        immutable double dPersp = c10 * (rp.eye[0] - kQc[0]) - s10 * (rp.eye[2] - kQc[2]);
        assert(dPersp > 0.2, format("5b rig: Q must face the perspective eye (%.3f)", dPersp));
        auto qc = qCorners();
        int[2][] qp;
        foreach (k; 0 .. 4) qp ~= toPx(qc[k], rp.vp);
        auto np = dotPixels(qp, 3);
        foreach (k; 0 .. 4)
            assert(np[k] >= kCornerDot, format("5b perspective: Q faces this eye; its corner %d "
                ~ "must draw a dot (%s px)", k, np[k]));
        frontOrtho();
        parkPointer(r);
    }

    // ---- 4p. a live subpatch preview draws every cage-derived dot ----------
    // Its vertex buffer is not in cage slots, so the cull must be off: F's
    // corner-derived points are drawn (each within a few pixels of the cage
    // corner on this open quad).
    {
        void waitPreview() {
            import core.thread : Thread;
            import core.time : msecs;
            foreach (_; 0 .. 1500) {
                auto j = getJson("/api/subpatch/preview");
                if (j["pending"].type != JSONType.true_) { settle(); return; }
                Thread.sleep(20.msecs);
            }
            assert(false, "4p: the subpatch preview build did not settle");
        }
        cmdOk(`{"id":"mesh.subpatch_toggle"}`);
        waitPreview();
        assert(jb(getJson("/api/subpatch/preview")["active"]),
            "4p premise: the subpatch preview must be active");
        auto n = dotPixels([px(kFOwn[0]), px(kFOwn[1]), px(kFOwn[2])], 4);
        foreach (k; 0 .. 3)
            assert(n[k] >= 5, format("4p: under the preview F's corner %s draws no dot "
                ~ "(%s px) — the cull ran on a buffer not in cage slots", kFOwn[k], n[k]));
        cmdOk(`{"id":"mesh.subpatch_toggle"}`);
        waitPreview();
        assert(!jb(getJson("/api/subpatch/preview")["active"]),
            "4p: the subpatch preview did not switch off");
    }

    // ---- 4h. a hidden face changes the dots (display epoch in the key) ------
    // Hide G: the shared corner is then voted on by F alone, faces away, and
    // loses its dot.
    {
        auto before = dotPixels([px(kShared)], 2)[0];
        assert(before >= kCornerDot, format("4h premise: the shared corner has no dot (%s)", before));
        cmdOk(commandBody("mesh.select", format(`{"mode":"polygons","indices":[%d]}`,
                                                idxOf(qs, "G"))));
        cmdOk(commandBody("mesh.hide"));
        settle();
        cmdOk(commandBody("mesh.select", `{"mode":"polygons","indices":[]}`));
        settle();
        auto after = dotPixels([px(kShared)], 2)[0];
        assert(after == 0, format("4h: with G hidden the shared corner still draws a "
            ~ "dot (%s px) — the dot list did not follow the hide", after));
        cmdOk(commandBody("mesh.unhideAll"));
        settle();
        assert(dotPixels([px(kShared)], 2)[0] >= kCornerDot, "4h: the unhide did not come back");
    }

    // ---- 4m. binding a morph target re-culls (display epoch in the key) ----
    // `mesh.morph.select` moves no vertex, no topology and no geometry epoch —
    // it publishes MapsDisplay only — yet the drawn positions change. The
    // morph swaps F's first and last own corners, which reverses F's winding
    // on screen: F faces the eye and all three own-corner pixels carry dots.
    // The on-reading is taken FIRST, before any showVertices toggle (a toggle
    // drops the cell's slot and forces a fresh list on its own).
    {
        auto pts3 = [px(kFOwn[0]), px(kFOwn[1]), px(kFOwn[2])];
        cmdOk(commandBody("mesh.morph.create", `{"name":"m4","kind":"relative"}`));
        cmdOk(commandBody("mesh.morph.select", `{"name":""}`));
        cmdOk(commandBody("mesh.morph.set", format(
            `{"name":"m4","vert":%d,"x":-0.6,"y":-0.6,"z":0}`, r.fg.fOwn[0])));
        cmdOk(commandBody("mesh.morph.set", format(
            `{"name":"m4","vert":%d,"x":0.6,"y":0.6,"z":0}`, r.fg.fOwn[2])));
        settle();
        auto pre = dotPixels(pts3, 2);
        foreach (k; 0 .. 3)
            assert(pre[k] == 0, format("4m premise: with no target bound F's corner %s "
                ~ "draws a dot (%s px)", kFOwn[k], pre[k]));
        immutable long b0 = recomputes(0);
        cmdOk(commandBody("mesh.morph.select", `{"name":"m4"}`));
        settle();
        frameFence(null, 2);
        immutable long dRe = recomputes(0) - b0;
        assert(dRe >= 1, format("4m: binding a morph target recomputed the dot list "
            ~ "%s times — the key does not read the display epoch", dRe));
        int[2][] pts;
        foreach (c; pts3) pts ~= window(c, 2);
        auto on = probe(pts);
        showVertices(false);
        auto off = probe(pts);
        showVertices(true);
        int[3] n = 0;
        foreach (i; 0 .. pts.length)
            if (maxDiff(on[i], off[i]) >= 3) ++n[i / 25];
        foreach (k; 0 .. 3)
            assert(n[k] >= kCornerDot, format("4m: with the morph bound F faces the eye, "
                ~ "yet the pixel %s draws no dot (%s px) — the list was culled at the "
                ~ "unmorphed positions", kFOwn[k], n[k]));
        cmdOk(commandBody("mesh.morph.select", `{"name":""}`));
        cmdOk(commandBody("mesh.morph.remove", `{"name":"m4"}`));
        settle();
        auto post = dotPixels(pts3, 2);
        foreach (k; 0 .. 3)
            assert(post[k] == 0, format("4m: after unbinding, F's corner %s still "
                ~ "draws a dot (%s px)", kFOwn[k], post[k]));
    }

    // ---- 5d. the cull is cached per cell and keyed on what it reads --------
    {
        cmdOk(commandBody("viewport.layout", `"SplitH"`));
        settle();
        foreach (k; 0 .. 2) {
            cmd("viewport.retopology", format(`{"value":"on","viewport":%d}`, k));
            cmd("viewport.showVertices", format(`{"value":"on","viewport":%d}`, k));
            auto cr = postJson(format("/api/camera?viewport=%d", k),
                `{"focus":{"x":0,"y":0,"z":0},"distance":9}`);
            assert(cr["status"].str == "ok", "5d camera: " ~ cr.toString);
        }
        settle();
        auto disp = getJson("/api/viewport/display");
        assert(disp["cellCount"].integer == 2 && jb(disp["cells"].array[0]["renders"])
            && jb(disp["cells"].array[1]["renders"]),
            "5d premise: two rendered cells: " ~ disp.toString);
        long[2] base() { return [recomputes(0), recomputes(1)]; }
        long[2] delta(long[2] b) { auto n = base(); return [n[0] - b[0], n[1] - b[1]]; }
        assert(recomputes(0) >= 1 && recomputes(1) >= 1,
            "5d premise: both cells computed a dot list");
        // (i) idle frames.
        auto b = base();
        frameFence(null, 3);
        auto d = delta(b);
        assert(d == [0, 0], format("5d(i): idle frames recomputed %s", d));
        // (ii) move cell 1's camera only.
        b = base();
        auto cr = postJson("/api/camera?viewport=1",
            `{"focus":{"x":0,"y":0,"z":0},"distance":11}`);
        assert(cr["status"].str == "ok", "5d camera: " ~ cr.toString);
        settle();
        frameFence(null, 2);
        d = delta(b);
        assert(d == [0, 1], format("5d(ii): a camera move in cell 1 recomputed %s "
            ~ "(expected [0, 1])", d));
        // (iii) hide a face.
        b = base();
        cmdOk(commandBody("mesh.select", `{"mode":"polygons","indices":[0]}`));
        cmdOk(commandBody("mesh.hide"));
        settle();
        frameFence(null, 2);
        d = delta(b);
        assert(d[0] >= 1 && d[1] >= 1, format("5d(iii): a hide recomputed %s", d));
        cmdOk(commandBody("mesh.unhideAll"));
        cmdOk(commandBody("mesh.select", `{"mode":"polygons","indices":[]}`));
        settle();
        // (iv) move the vertices.
        b = base();
        cmdOk(`{"id":"mesh.transform","params":{"kind":"translate","delta":[0,0,0.01]}}`);
        settle();
        frameFence(null, 2);
        d = delta(b);
        assert(d[0] >= 1 && d[1] >= 1, format("5d(iv): a vertex move recomputed %s", d));
        cmdOk(`{"id":"mesh.transform","params":{"kind":"translate","delta":[0,0,-0.01]}}`);
        cmdOk(commandBody("viewport.layout", `"Single"`));
        settle();
        frontOrtho();
        cmd("viewport.retopology", `{"value":"on"}`);
        showVertices(true);
        parkPointer(r);
    }

    // ---- 5e / 5f. mirror the FOREGROUND layer in place (scl.x = -1) ---------
    {
        cmdOk("layer.attr 1 scl.x -1");
        settle();
        auto xf = getJson("/api/layers")["layers"].array[1]["xform"];
        assert(num(xf["scl"].array[0]) == -1.0,
            "5e precondition: layer 1 scl.x must read back -1: " ~ xf.toString);
        double[3] mx(double[3] p) { return [-p[0], p[1], p[2]]; }
        // 5e: the fill culls the same polygons as unmirrored (S3's 7b), and the
        // dots agree with it: F's own corners still absent, the shared corner
        // and I0 still present.
        auto n = dotPixels([px(mx(kFOwn[0])), px(mx(kFOwn[1])), px(mx(kFOwn[2])),
                            px(mx(kShared)), px(mx(kI0Pos))], 2);
        foreach (k; 0 .. 3)
            assert(n[k] == 0, format("5e: mirrored F's corner %s draws a dot (%s px) — "
                ~ "the dots disagree with the fill's cull", kFOwn[k], n[k]));
        assert(n[3] >= kCornerDot && n[4] >= 9,
            format("5e: mirrored shared corner / I0 lost their dots (%s, %s px)", n[3], n[4]));
        // 5f: the mirrored edge colour equals the unmirrored one (mat3(M)·z =
        // +z under scl.x = -1). Each unblended value carries 2.0 LSB.
        double[3][4] mc = cq("EA");
        foreach (ref p; mc) p = mx(p);
        Px u, o;
        auto e = edgeColour(mc, r.vp, u, o);
        foreach (c; 0 .. 3)
            assert(abs(e[c] - e0["EA"][c]) <= 4.0,
                format("5f: the mirrored edge channel %d unblends to %.1f, unmirrored "
                       ~ "%.1f", c, e[c], e0["EA"][c]));
        cmdOk("layer.attr 1 scl.x 1");
        settle();
    }

    // ---- 6. mode-off control: the base wire is the scheme's opaque grey -----
    {
        cmd("viewport.retopology", `{"value":"off"}`);
        showVertices(false);
        auto cs = cq("EG");
        immutable double[3] mid = [(cs[0][0] + cs[1][0]) / 2, (cs[0][1] + cs[1][1]) / 2, 0.5];
        auto p = px(mid);
        auto o = probe([[p[0], p[1] - 1], [p[0], p[1]], [p[0], p[1] + 1]]);
        bool found = false;
        foreach (x; o) if (x.c[0] == 184 && x.c[1] == 184 && x.c[2] == 184) found = true;
        assert(found, format("6: with the mode off no row at EG's edge reads the "
            ~ "scheme wireframe 184 (%s)", o));
        // Mode off does not cull: F's own corners draw their dots.
        auto n = dotPixels([px(kFOwn[0]), px(kFOwn[1]), px(kFOwn[2])], 2);
        foreach (k; 0 .. 3)
            assert(n[k] >= kCornerDot, format("6: with the mode off F's corner %s "
                ~ "draws no dot (%s px) — the cull ran outside its plan bit",
                kFOwn[k], n[k]));
        showVertices(false);
    }

    // ---- 7. mode-off control: a vertex hover under the polygon type --------
    // Vertex dots off, polygon selection type, a tool that picks and draws a
    // vertex rollover (xfrm.elementMove — its element falloff answers
    // `Rollover.vertices`; a tool whose rollover policy is `none`, such as
    // xfrm.pointAttract, never reaches the arm): the hover-only arm runs, and
    // with the mode off its plan lets the selection decide, so a hovered
    // vertex brings every base dot with it — far from the pointer, EA's
    // corners light up. Both readings keep the tool active; only the hover
    // differs. With the mode on the same hover draws none (the other side).
    {
        cmdOk("select.typeFrom polygon");
        cmdOk("tool.set xfrm.elementMove");
        settle();
        int hoverV() {
            return cast(int) getJson("/api/toolpipe/eval")["hover"]["vertex"].integer;
        }
        auto ea = cq("EA");
        int[2][] cs = [px(ea[0]), px(ea[2])];
        int[2][] pts;
        foreach (c; cs) pts ~= window(c, 2);
        void hoverI0() {
            immutable int[2] ip = px(kI0Pos);
            string log = format(`{"t":0,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,`
                ~ `"vpH":%d,"fovY":0.785398}`, r.vp.x, r.vp.y, r.vp.width, r.vp.height) ~ "\n";
            foreach (i; 0 .. 3)
                log ~= format(`{"t":%d,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,`
                    ~ `"yrel":0,"state":0,"mod":0}`, 30 + i * 20, r.vp.x + ip[0],
                    r.vp.y + ip[1]) ~ "\n";
            auto pr = postJson("/api/play-events", log);
            assert(pr["status"].str == "success", "7: /api/play-events failed: " ~ pr.toString);
            waitPlaybackProcessed();
            settle();
            assert(hoverV() == kI0, format("7 premise: the pointer on I0 hovers vertex %s",
                                            hoverV()));
        }
        hoverI0();
        auto hov = probe(pts);
        parkPointer(r);
        assert(hoverV() == -1, format("7 premise: the parked pointer still hovers "
            ~ "vertex %s", hoverV()));
        auto none = probe(pts);
        int[2] n = 0;
        foreach (i; 0 .. pts.length)
            if (maxDiff(hov[i], none[i]) >= 3) ++n[i / 25];
        foreach (k; 0 .. 2)
            assert(n[k] >= kCornerDot, format("7: with the mode off a vertex hover under "
                ~ "the polygon type draws no base dot at EA's corner %s (%s px)",
                cs[k], n[k]));
        // ...and they are the dots vertex display would draw: the same pixels.
        showVertices(true);
        auto sv = probe(pts);
        showVertices(false);
        foreach (i; 0 .. pts.length)
            assert(maxDiff(hov[i], sv[i]) <= 1, format("7: the hover's base dot at %s "
                ~ "reads %s, vertex display draws %s", pts[i], hov[i].c, sv[i].c));
        // The mirror: with the mode ON the plan takes the base dots away from
        // the selection, so the same hover leaves EA's corners untouched.
        cmd("viewport.retopology", `{"value":"on"}`);
        showVertices(false);
        hoverI0();
        auto hovOn = probe(pts);
        parkPointer(r);
        auto noneOn = probe(pts);
        int changed = 0;
        foreach (i; 0 .. pts.length) if (maxDiff(hovOn[i], noneOn[i]) >= 3) ++changed;
        assert(changed == 0, format("7: with the mode on a vertex hover draws base dots "
            ~ "(%s px changed around EA's corners)", changed));
        cmd("viewport.retopology", `{"value":"off"}`);
        cmdOk("tool.set xfrm.elementMove off");
        settle();
    }
    writeln("  test_retopology_lines_dots: all cells passed");
}

unittest { // perspective lens-only consumed A/B/A at a stable draw population
    cmdOk("scene.reset");cmdOk("viewport.view Perspective");
    cmd("viewport.retopology",`{"value":"on"}`);showVertices(true);settle();
    auto display(){return getJson("/api/viewport/display");}
    const population=getJson("/api/layers")["layers"].array.length;
    assert(population==1,"DOT_LENS_HTTP_ITEM_FLOOR");
    const mesh=getJson("/api/model");
    auto start=display();
    const layers=getJson("/api/layers")["layers"];
    const bus=getJson("/api/changes");
    const cell=start["cells"].array[0];
    assert(jb(cell["renders"])&&!jb(cell["ortho"])&&jb(cell["state"]["retopology"])&&
           jb(cell["plan"]["active"]["cullHiddenVerts"]),"DOT_LENS_HTTP_ACTUAL_DRAW_PLAN");
    assert(!jb(getJson("/api/subpatch/preview")["active"]),"DOT_LENS_HTTP_NO_PREVIEW");
    // Actual cell diagnostics count once per drawn item mesh.
    auto counter(JSONValue j){return num(j["cells"].array[0]["dotCullRecomputes"]);}
    foreach(lens;[.9026584025557545,cast(double)cast(float)(45.0f*PI/180.0f)]) {
        const before=counter(display());
        assert(postJson("/api/camera",format(`{"fovY":%.17g}`,lens))["status"].str=="ok");settle();
        assert(counter(display())==before+population,"DOT_LENS_HTTP_CONSUMED_RECOMPUTES");
        const count=counter(display());settle();
        assert(counter(display())==count,"DOT_LENS_HTTP_SETTLED");
        assert(postJson("/api/camera",format(`{"fovY":%.17g}`,lens))["status"].str=="ok");
        getJson("/api/camera");settle();assert(counter(display())==count,"DOT_LENS_HTTP_SAME_READ");
        assert(postJson("/api/camera",`{"fovY":1e-29}`)["status"].str=="error");settle();
        assert(counter(display())==count,"DOT_LENS_HTTP_REFUSAL");
        assert(getJson("/api/model")["vertices"]==mesh["vertices"],"DOT_LENS_HTTP_NO_MESH_WRITE");
        assert(getJson("/api/layers")["layers"]==layers,"DOT_LENS_HTTP_STABLE_ITEMS_MODEL_VERSION");
        const current=display()["cells"].array[0];
        assert(current["state"]==cell["state"]&&current["plan"]==cell["plan"]&&current["selEpoch"]==cell["selEpoch"],"DOT_LENS_HTTP_STABLE_DISPLAY");
        const now=getJson("/api/changes");
        foreach(key;["totalPosition","totalPoints","totalPolygons","totalMarks","totalSelItem","totalLayerVisible"])
            assert(now[key]==bus[key],"DOT_LENS_HTTP_NO_EPOCH_PUBLICATION "~key);
    }
}
