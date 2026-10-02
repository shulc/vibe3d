// test_retopology_multi_item.d — every item through the same bracket under
// the retopology display mode: the non-primary foreground items, a joined
// same-as-active backdrop, their order around the primary, their own
// materials, and the primary's selection feedback after the whole sequence.
//
// Captured laws (plan §10.3/§10.4/§10.12): items draw in REVERSE layer order,
// each on its own depth clear; a same-as-active backdrop joins that order with
// no clear of its own; the primary's selection passes follow the LAST item,
// depth-tested, with the occluded pass.
//
// Rigs: OPEN quads only, front orthographic camera. Rig M: layer 0 background
// (P1, a big +Z quad), layers 1..3 foreground with 2 the primary. Rig J:
// layer 0 background (P1), layer 1 the primary. Rig N: one layer and no edit
// target. Rig F: `tests/fixtures/two_layer_distinct_surfaces.v3d`, two layers
// with different surface colours. Every "under" value is PROBED with the
// layers in question moved out of the view (a hidden primary is still drawn,
// backlog 8559), never typed.
//
// TOLERANCES come from 8-bit quantisation: every read value is +-0.5 LSB and
// each derived quantity carries its propagated error, stated beside it.
module test_retopology_multi_item;

import http_client : getJson, postJson, quiesce, frameFence, waitPlaybackProcessed;
import http_command_helpers : commandBody;
import drag_helpers : viewportFromCameraMatrices, projectToWindow,
                      Viewport, DHVec3 = Vec3;
import std.json;
import std.format : format;
import std.math : abs, round, sqrt, pow;
import std.algorithm : max;
import std.conv : to;
import std.path : buildPath, dirName;
import std.stdio : writeln, writefln;

void main() {}

// Our light rig (source/light_rig.d, task 9130: eye-space key and fill, global
// ambient, no specular on the default material or the Retopology arm) and the
// mode's constants — the relations under test are on OUR lighting.
private enum double kAmbient = 0.15, kKeyI = 0.7, kFillI = 0.3;
private immutable double[3] kKeyEye = [-0.654509, 0.587785, 0.475528];
private enum double kGain = 5.0 / 3.0;
private enum double kFill = 0.5;           // the mode's face alpha
private enum double kLineAlpha = 0.4;
private enum double kOccluded = 0.30;       // the occluded selection pass
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
// Our light function, in doubles
// ---------------------------------------------------------------------------
private double[3] nrm(double[3] v) {
    immutable l = sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    return [v[0] / l, v[1] / l, v[2] / l];
}
private double dot3(double[3] a, double[3] b) { return a[0]*b[0] + a[1]*b[1] + a[2]*b[2]; }

/// 255 x a +Z polygon of base colour channel `base` seen through `vp`, gain
/// g: the world +Z normal is taken to eye space by the view (the rig turns
/// with the camera; under the front view it is the eye's +Z).
private double litZ(double base, const ref Viewport vp, double g) {
    immutable N = nrm([vp.view[8], vp.view[9], vp.view[10]]);   // view · (0,0,1)
    immutable dif = kKeyI * max(0.0, dot3(N, kKeyEye)) + kFillI * max(0.0, N[0]);
    return 255.0 * base * (kAmbient + g * dif);
}

// ---------------------------------------------------------------------------
// Rig geometry
// ---------------------------------------------------------------------------
/// One quad: centre, half-extents, z, corners bottom-left, bottom-right,
/// top-right, top-left — counter-clockwise from +Z unless `reversed`.
private struct Quad {
    string    name;
    double[2] c;
    double[2] h;
    double    z;
    bool      reversed;
}
private Quad q(string n, double x, double y, double hx, double hy, double z,
               bool rev = false) {
    return Quad(n, [x, y], [hx, hy], z, rev);
}

private double[3][4] corners(Quad v) {
    return [[v.c[0] - v.h[0], v.c[1] - v.h[1], v.z], [v.c[0] + v.h[0], v.c[1] - v.h[1], v.z],
            [v.c[0] + v.h[0], v.c[1] + v.h[1], v.z], [v.c[0] - v.h[0], v.c[1] + v.h[1], v.z]];
}
private double[3] centre(Quad v) { return [v.c[0], v.c[1], v.z]; }

private JSONValue meshJson(Quad[] qs) {
    JSONValue[] verts, faces;
    foreach (v; qs) {
        long[] f;
        foreach (p; corners(v)) {
            verts ~= JSONValue([p[0], p[1], p[2]]);
            f ~= cast(long)(verts.length - 1);
        }
        if (v.reversed) f = [f[3], f[2], f[1], f[0]];
        faces ~= JSONValue(f);
    }
    return JSONValue(["vertices": JSONValue(verts), "faces": JSONValue(faces)]);
}

private struct Rig {
    Viewport vp;
    double[3] eye;
}

private int[2] toPx(double[3] w, ref Viewport vp) {
    float px, py;
    assert(projectToWindow(DHVec3(cast(float) w[0], cast(float) w[1], cast(float) w[2]),
                           vp, px, py), "rig point projects behind the camera");
    return [cast(int) round(px) - vp.x, cast(int) round(py) - vp.y];
}

private Rig frontOrtho() {
    cmdOk("viewport.view Front");
    settle();
    auto cr = postJson("/api/camera?viewport=0",
        `{"focus":{"x":0,"y":0,"z":0},"distance":9}`);
    assert(cr["status"].str == "ok", "camera: " ~ cr.toString);
    settle();
    auto cam = getJson("/api/camera?viewport=0");
    assert(cam["projKind"].str != "Perspective" && cam["viewPreset"].str == "Front",
        "rig: the cell must be in the orthographic Front view: " ~ cam.toString);
    Rig r;
    r.vp = viewportFromCameraMatrices();
    assert(r.vp.proj[15] != 0.0f, "rig: the Front view must be orthographic");
    r.eye = [r.vp.eye.x, r.vp.eye.y, r.vp.eye.z];
    assert(r.eye[2] > 1.0, format("rig: the eye must sit on +Z, got %s", r.eye));
    return r;
}

/// Every point inside the cell with a margin.
private void assertInside(ref Rig r, double[3][] ws) {
    foreach (w; ws) {
        auto p = toPx(w, r.vp);
        assert(p[0] > 10 && p[1] > 10 && p[0] < r.vp.width - 10 && p[1] < r.vp.height - 10,
            format("rig: point %s projects to %s, outside the %sx%s cell",
                   w, p, r.vp.width, r.vp.height));
    }
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

private JSONValue layersJson() { return getJson("/api/layers"); }
private JSONValue layerAt(int i) { return layersJson()["layers"].array[i]; }

// ---------------------------------------------------------------------------
// Probing
// ---------------------------------------------------------------------------
private struct Px { int[4] c; }

private Px[] probe(int[2][] pts) {
    string s = "/api/viewport/probe?cell=0&points=";
    foreach (k, p; pts) s ~= format("%s%d,%d", k ? ";" : "", p[0], p[1]);
    auto j = getJson(s);
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

private int maxDiff(Px a, Px b) {
    int m = 0;
    foreach (k; 0 .. 3) m = max(m, abs(a.c[k] - b.c[k]));
    return m;
}

/// The pixels at `pts` with layers `idx` moved out of the view (pos.x 1000)
/// and back, each move read back.
private Px[] under(int[2][] pts, int[] idx) {
    double posX(int i) { return num(layerAt(i)["xform"]["pos"].array[0]); }
    foreach (i; idx) {
        assert(posX(i) == 0.0, format("under: layer %d must start at pos.x 0", i));
        cmdOk(format("layer.attr %d pos.x 1000", i));
    }
    settle();
    foreach (i; idx)
        assert(posX(i) == 1000.0, format("under: layer %d did not move away", i));
    auto u = probe(pts);
    foreach (i; idx) cmdOk(format("layer.attr %d pos.x 0", i));
    settle();
    foreach (i; idx)
        assert(posX(i) == 0.0, format("under: layer %d did not come back", i));
    return u;
}

/// Pixels of the square window of half-size `h` around `p`.
private int[2][] window(int[2] p, int h) {
    int[2][] o;
    foreach (dy; -h .. h + 1)
        foreach (dx; -h .. h + 1) o ~= [p[0] + dx, p[1] + dy];
    return o;
}

/// Pixels a 3 px dot at a polygon CORNER changes (measured in S4: the corner's
/// own edges keep their middle row and column, so four of nine remain).
private enum int kCornerDot = 4;

/// How many pixels of each window change between vertex dots off and on.
private int[] dotPixels(int[2][] centres, int h) {
    int[2][] pts;
    foreach (c; centres) pts ~= window(c, h);
    cmd("viewport.showVertices", `{"value":"off"}`);
    auto off = probe(pts);
    cmd("viewport.showVertices", `{"value":"on"}`);
    auto on = probe(pts);
    immutable size_t w = (2 * h + 1) * (2 * h + 1);
    int[] n = new int[](centres.length);
    foreach (i; 0 .. pts.length)
        if (maxDiff(on[i], off[i]) >= 3) ++n[i / w];
    return n;
}

/// The unblended fill `(out - (1-a) u) / a` of a pixel; error (0.5+0.5(1-a))/a.
private double[3] unblend(Px o, Px u, double a) {
    double[3] c;
    foreach (k; 0 .. 3) c[k] = (o.c[k] - (1 - a) * u.c[k]) / a;
    return c;
}

private long frameNow() { return getJson("/api/play-events/status")["frame"].integer; }
private long recomputes() {
    return getJson("/api/viewport/display")["cells"].array[0]["dotCullRecomputes"].integer;
}

// ===========================================================================
// Rig M — three foreground layers around the primary, one background
// ===========================================================================
// Layer 0 (background): P1. Layer 1 and 3 foreground, layer 2 the primary.
// Draw sequence: 3, [2], 1 (reverse layer order around the primary).
//   B1/B2/B3   one small quad per item BEHIND P1 (z = -0.5)       cell 3
//   X2 (L2, z=+0.5) and X1o (L1, z=-0.5) overlap over empty view  cell 1
//   X3 (L3) and X1 (L1): fills; R3 (L3) and R1 (L1): REVERSED     cell 2
//     quads — unfilled under the mode — whose vertical edges run
//     through the other item's fill: R3's right edge through X1,
//     R1's left edge through X3
//   R2 (L2): reversed, for the per-item dot cull                  cell 5
//   R2b (L2): reversed, its left edge through X1 (L1 after L2)     cell 2
//   G2 (L2): a small front quad inside X1o; its corner dot         cell 5b
// L3's quads map to empty view under x -> -x (cells 6 / 6b).
private immutable Quad kP1  = Quad("P1", [-2.2, -1.1], [0.7, 0.7], 0.0, false);
private immutable Quad kB1  = Quad("B1", [-1.9, -0.9], [0.18, 0.18], -0.5, false);
private immutable Quad kB2  = Quad("B2", [-2.6, -0.9], [0.18, 0.18], -0.5, false);
private immutable Quad kB3  = Quad("B3", [-2.25, -1.45], [0.18, 0.18], -0.5, false);
private immutable Quad kX2  = Quad("X2", [-0.3, -1.2], [0.6, 0.45], 0.5, false);
private immutable Quad kX1o = Quad("X1o", [0.5, -1.2], [0.6, 0.45], -0.5, false);
private immutable Quad kX3  = Quad("X3", [0.9, 0.9], [0.45, 0.45], 0.0, false);
private immutable Quad kX1  = Quad("X1", [2.4, 0.9], [0.45, 0.45], 0.0, false);
private immutable Quad kR3  = Quad("R3", [2.0, 0.6], [0.4, 0.5], 0.0, true);
private immutable Quad kR1  = Quad("R1", [1.2, 1.325], [0.3, 0.425], 0.0, true);
private immutable Quad kR2  = Quad("R2", [2.6, -0.5], [0.25, 0.25], 0.0, true);
private immutable Quad kR2b = Quad("R2b", [2.85, 1.35], [0.2, 0.35], 0.0, true);
private immutable Quad kG2  = Quad("G2", [0.8, -1.4], [0.15, 0.15], 0.0, false);

private Rig buildRigM() {
    cmdOk(commandBody("scene.reset"));
    cmdOk(`{"id":"history.clear"}`);
    cmdOk(commandBody("viewport.layout", `"Single"`));
    immutable Quad[][4] content = [[kP1], [kB1, kX1o, kX1, kR1], [kB2, kX2, kR2, kR2b, kG2],
                                   [kB3, kX3, kR3]];
    foreach (i, qs; content) {
        if (i > 0) cmdOk(`{"id":"layer.add"}`);
        cmdOk(commandBody("scene.loadMesh", meshJson(qs.dup).toString));
    }
    cmdOk(`{"id":"layer.select","index":2,"mode":"set"}`);
    cmdOk(`{"id":"layer.select","index":1,"mode":"add"}`);
    cmdOk(`{"id":"layer.select","index":3,"mode":"add"}`);
    // An item select makes the ITEM type current, whose feedback repaints the
    // selected items' wireframes; the cells read geometry under polygon type.
    cmdOk("select.typeFrom polygon");
    auto r = frontOrtho();
    cmd("viewport.displayStyle", `{"value":"shaded"}`);
    cmd("viewport.backdropStyle", `{"value":"flat"}`);
    auto L = layersJson();
    auto ls = L["layers"].array;
    assert(ls.length == 4 && L["active"].integer == 2,
        "rig M: four layers with layer 2 the primary: " ~ L.toString);
    assert(jb(ls[0]["background"]) && !jb(ls[0]["foreground"]),
        "rig M: layer 0 must be background: " ~ L.toString);
    foreach (i; [1, 3])
        assert(jb(ls[i]["foreground"]) && !jb(ls[i]["primary"]) && jb(ls[i]["visible"]),
            format("rig M: layer %d must be a visible non-primary foreground layer: %s",
                   i, L.toString));
    double[3][] pts;
    foreach (qs; content) foreach (v; qs) pts ~= corners(v);
    assertInside(r, pts);
    parkPointer(r);
    return r;
}

unittest {
    auto r = buildRigM();
    scope (exit) {
        cmdRaw(commandBody("viewport.retopology", `{"value":"off"}`));
        cmdRaw(commandBody("viewport.showVertices", `{"value":"off"}`));
        cmdRaw(commandBody("viewport.backdropStyle", `{"value":"same"}`));
        cmdRaw("viewport.view Perspective");
    }
    int[2] px(double[3] w) { return toPx(w, r.vp); }
    int[2] pxq(Quad v) { return toPx(centre(v), r.vp); }

    cmd("viewport.retopology", `{"value":"on"}`);
    {
        auto p = getJson("/api/viewport/display")["cells"].array[0]["plan"];
        assert(jb(p["active"]["clearDepthFirst"]) && !jb(p["backdrop"]["joinsItemSequence"])
            && abs(num(p["active"]["faceAlpha"]) - kFill) < 1e-6,
            "premise: the mode clears per item, the flat backdrop does not join: "
            ~ p.toString);
    }

    // ---- 3. every item behind the backdrop is visible (its own clear) -----
    // B_i = a c_i + (1-a) P1, c_i unblended from the item's X fill over the
    // empty view (1.5 LSB), P1 read with the three items moved away:
    // 0.5 + a 1.5 + (1-a) 0.5 = 1.5.
    {
        immutable double[3] x3 = [0.7, 0.7, 0.0];   // inside X3, away from R1
        int[2][] pts = [pxq(kB1), pxq(kB2), pxq(kB3),
                        px([0.45, -1.0, 0.0]), px([-0.7, -1.2, 0.0]), px(x3)];
        auto u = under(pts, [1, 2, 3]);
        auto o = probe(pts);
        writefln("  3 under %s", u);
        writefln("  3 on    %s", o);
        foreach (i; 0 .. 3) {
            immutable c = unblend(o[3 + i], u[3 + i], kFill);
            assert(maxDiff(o[i], u[i]) >= 5,
                format("3: B%d reads its under value %s — the item behind the backdrop "
                       ~ "is hidden (no depth clear of its own)", i + 1, u[i].c));
            foreach (k; 0 .. 3) {
                immutable double pred = kFill * c[k] + (1 - kFill) * u[i].c[k];
                assert(abs(o[i].c[k] - pred) <= 1.5,
                    format("3: B%d channel %d reads %d, predicted %.2f = a c + (1-a) P1 "
                           ~ "(tolerance 1.5)", i + 1, k, o[i].c[k], pred));
            }
        }
    }

    // ---- 1. overlap of the primary and a later item: no cross-item occlusion
    // X1o (L1, z = -0.5, drawn after the primary on its own clear) over X2
    // (z = +0.5): out = a c1 + (1-a)(a c2 + (1-a) u), c1 and c2 unblended
    // from each quad alone (1.5 each), u probed: 0.5 + a 1.5 + (1-a)(a 1.5 +
    // (1-a) 0.5) = 1.25 + 0.5 0.875 = 1.69 -> 1.75. The rival (X1o occluded by
    // X2's depth) reads X2 alone.
    {
        int[2][] pts = [px([0.1, -1.2, 0.0]), px([0.45, -1.0, 0.0]), px([-0.6, -1.2, 0.0])];
        auto u = under(pts, [1, 2, 3]);
        auto o = probe(pts);
        immutable c1 = unblend(o[1], u[1], kFill);
        immutable c2 = unblend(o[2], u[2], kFill);
        writefln("  1 overlap %s alone %s %s under %s", o[0].c, o[1].c, o[2].c, u[0].c);
        bool discriminates = false;
        foreach (k; 0 .. 3) {
            immutable double single = kFill * c2[k] + (1 - kFill) * u[0].c[k];
            immutable double pred = kFill * c1[k] + (1 - kFill) * single;
            if (abs(pred - single) > 2 * 1.75) discriminates = true;
            assert(abs(o[0].c[k] - pred) <= 1.75,
                format("1: the overlap channel %d reads %d, predicted %.2f = a c1 + (1-a)"
                       ~ "(a c2 + (1-a) u) (tolerance 1.75); X2 alone would read %.2f",
                       k, o[0].c[k], pred, single));
        }
        assert(discriminates, "1 premise: the double and single blends agree on this rig");
        // The two fills are the same plan on the same normal: a non-primary
        // item takes the active plan's shading, fill colour and gain (each
        // unblended value carries 1.5).
        foreach (k; 0 .. 3)
            assert(abs(c1[k] - c2[k]) <= 3.0,
                format("1: layer 1's fill unblends to %s, the primary's to %s — the item "
                       ~ "is not drawn with the active plan", c1, c2));
    }

    // ---- 1c. the non-primary items count as backdrop work -----------------
    // Faces of layers 0, 1 and 3 (P1 by the backdrop pass, the others by the
    // sequence) go to `bgFaces`; `faces` holds the primary's alone. Six fan
    // vertices per quad.
    {
        auto sc = getJson("/api/frames/counts")["lastScene"];
        immutable long faces = sc["pass"]["faces"]["verts"].integer;
        immutable long bg = sc["pass"]["bgFaces"]["verts"].integer;
        assert(faces == 6 * 5 && bg == 6 * (1 + 4 + 3),
            format("1c: faces %d / bgFaces %d verts, expected %d / %d — the item "
                   ~ "sequence must stay attributed to the backdrop counters",
                   faces, bg, 6 * 5, 6 * 8));
    }

    // ---- 2. veiling follows the reverse layer order: 3 before 1 ------------
    // An edge of a REVERSED quad blends straight over what is under it:
    // E = 0.4 e + 0.6 u, read where the edge leaves the other item's fill.
    // Inside the other item's fill, with L3 drawn FIRST and L1 LAST:
    //   R3's edge in X1 (veiled):   a c1 + (1-a)(E3 + 0.6 (u_in - u_out))
    //   R1's edge in X3 (unveiled): 0.4 e1 + 0.6 (a c3 + (1-a) u_in)
    // Tolerance: c 1.5 (x a), E 0.5 (x (1-a)), the two u 0.5 each (x 0.3 or
    // x 0.6 through e), read 0.5 -> at most 0.75 + 0.25 + 0.3 + 0.5 = 1.8 for
    // the first and 0.4 2.0 + 0.6 (0.75 + 0.25) + 0.5 = 1.9 for the second: 2.0.
    // The forward order swaps the two formulas; the cell asserts they differ.
    {
        // The column the vertical edge rasterises on: the one of three that
        // changed most over the empty view.
        int edgeColumn(double x, double yOut, int[] layersAway) {
            immutable int[2] at = px([x, yOut, 0.0]);
            int[2][] cols = [[at[0] - 1, at[1]], [at[0], at[1]], [at[0] + 1, at[1]]];
            auto u = under(cols, layersAway);
            auto o = probe(cols);
            int best = 0;
            foreach (i; 1 .. 3) if (maxDiff(o[i], u[i]) > maxDiff(o[best], u[best])) best = i;
            assert(maxDiff(o[best], u[best]) >= 3,
                format("2 premise: no edge at x %.2f (%s over %s)", x, o[best].c, u[best].c));
            return at[0] - 1 + best;
        }
        struct Veil { double[3] pred, rival; Px got; }
        // `edgeItem`'s edge at world x, over empty view at yOut and inside the
        // other item's fill at yIn; `fillAt` is inside that fill, off the edge.
        Veil read(double x, double yOut, double yIn, double[3] fillAt, bool veiled) {
            immutable int col = edgeColumn(x, yOut, [1, 2, 3]);
            int[2] pOut = [col, px([x, yOut, 0.0])[1]];
            int[2] pIn  = [col, px([x, yIn, 0.0])[1]];
            int[2][] pts = [pOut, pIn, px(fillAt)];
            auto u = under(pts, [1, 2, 3]);
            auto o = probe(pts);
            immutable c = unblend(o[2], u[2], kFill);
            Veil v;
            v.got = o[1];
            foreach (k; 0 .. 3) {
                immutable double e = (o[0].c[k] - (1 - kLineAlpha) * u[0].c[k]) / kLineAlpha;
                immutable double edgeIn = kLineAlpha * e + (1 - kLineAlpha) * u[1].c[k];
                immutable double fillIn = kFill * c[k] + (1 - kFill) * u[1].c[k];
                immutable double under_ = kFill * c[k] + (1 - kFill) * edgeIn;  // edge first
                immutable double over_  = kLineAlpha * e + (1 - kLineAlpha) * fillIn;
                v.pred[k]  = veiled ? under_ : over_;
                v.rival[k] = veiled ? over_ : under_;
            }
            return v;
        }
        immutable Veil v3 = read(kR3.c[0] + kR3.h[0], 0.25, 0.9, [2.2, 0.8, 0.0], true);
        // The primary sits between them: its R2b edge is veiled by layer 1 too,
        // and only once — its base wire is not drawn again with the feedback.
        immutable Veil v2 = read(kR2b.c[0] - kR2b.h[0], 1.55, 1.2, [2.2, 0.8, 0.0], true);
        immutable Veil v1 = read(kR1.c[0] - kR1.h[0], 1.55, 1.15, [0.65, 0.7, 0.0], false);
        writefln("  2 R3 edge in X1: got %s pred %s rival %s", v3.got.c, v3.pred, v3.rival);
        writefln("  2 R1 edge in X3: got %s pred %s rival %s", v1.got.c, v1.pred, v1.rival);
        writefln("  2 R2b edge in X1: got %s pred %s rival %s", v2.got.c, v2.pred, v2.rival);
        bool disc3 = false, disc1 = false, disc2 = false;
        foreach (k; 0 .. 3) {
            if (abs(v3.pred[k] - v3.rival[k]) > 4.0) disc3 = true;
            if (abs(v1.pred[k] - v1.rival[k]) > 4.0) disc1 = true;
            if (abs(v2.pred[k] - v2.rival[k]) > 4.0) disc2 = true;
        }
        assert(disc3 && disc1 && disc2, "2 premise: the veiled and unveiled predictions agree");
        foreach (k; 0 .. 3) {
            assert(abs(v3.got.c[k] - v3.pred[k]) <= 2.0,
                format("2: layer 3's edge inside layer 1's fill, channel %d reads %d, "
                       ~ "predicted %.2f VEILED (layer 3 drawn before layer 1); drawn "
                       ~ "after it would read %.2f", k, v3.got.c[k], v3.pred[k], v3.rival[k]));
            assert(abs(v1.got.c[k] - v1.pred[k]) <= 2.0,
                format("2: layer 1's edge inside layer 3's fill, channel %d reads %d, "
                       ~ "predicted %.2f UNVEILED (layer 1 drawn last); veiled would "
                       ~ "read %.2f", k, v1.got.c[k], v1.pred[k], v1.rival[k]));
            assert(abs(v2.got.c[k] - v2.pred[k]) <= 2.0,
                format("2: the primary's edge inside layer 1's fill, channel %d reads %d, "
                       ~ "predicted %.2f VEILED (the primary drawn before layer 1, its base "
                       ~ "wire once); unveiled would read %.2f", k, v2.got.c[k], v2.pred[k],
                       v2.rival[k]));
        }
    }

    // ---- 5. the dot cull per (cell, item): each item culls its own corners,
    // and idle frames recompute nothing although three meshes share the cell.
    {
        int[2][] cs = [px([1.6, 0.1, 0.0]), px([2.4, 0.1, 0.0]),     // R3 (L3)
                       px([0.9, 1.75, 0.0]), px([1.5, 1.75, 0.0]),   // R1 (L1)
                       px([2.35, -0.75, 0.0]), px([2.85, -0.25, 0.0]), // R2 (L2)
                       px([0.45, 0.45, 0.0]), px([2.85, 0.45, 0.0]),  // X3, X1
                       px([-0.9, -0.75, 0.0])];                       // X2
        auto n = dotPixels(cs, 2);
        writefln("  5 dot pixels %s", n);
        foreach (k; 0 .. 6)
            assert(n[k] == 0, format("5: reversed-quad corner %d draws a dot (%s px) — "
                ~ "its item's cull did not drop it", k, n[k]));
        foreach (k; 6 .. 9)
            assert(n[k] >= kCornerDot, format("5: front corner %d lost its dot (%s px)",
                                              k, n[k]));
        immutable long rc0 = recomputes();
        assert(rc0 >= 3, format("5 premise: three items culled, recomputes %d", rc0));
        immutable long f0 = frameNow();
        frameFence(null, 3);
        immutable long f1 = frameNow(), rc1 = recomputes();
        assert(f1 - f0 >= 2, format("5 floor: only %d frames passed", f1 - f0));
        assert(rc1 == rc0, format("5: %d idle frames recomputed the dot lists %d times "
            ~ "— the three items' slots evict each other", f1 - f0, rc1 - rc0));
    }

    // ---- 5b. the primary's base dots are drawn once, in its bracket --------
    // G2's corner dot lies inside X1o (layer 1, drawn after the primary), so
    // the dot is veiled: on - off = (1-a) 0.4 (d - Z), Z = (off - a c1)/(1-a)
    // the pixel before X1o, d the dot colour (vertex palette x our light at
    // +Z, gain 5/3). Error: Z 2.5 (x 0.2), d 0.5 (x 0.2), off 0.5, read 0.5:
    // 1.6 -> 2.0. A second base pass with the feedback would draw it over X1o.
    {
        int[2][] win = window(px([0.95, -1.25, 0.0]), 2);
        int[2][] pts = win ~ [px([0.45, -1.0, 0.0])];
        auto u = under(pts, [1, 2, 3]);
        cmd("viewport.showVertices", `{"value":"off"}`);
        auto off = probe(pts);
        cmd("viewport.showVertices", `{"value":"on"}`);
        auto on = probe(pts);
        immutable c1 = unblend(off[$ - 1], u[$ - 1], kFill);
        size_t best = 0;
        foreach (i; 1 .. win.length)
            if (maxDiff(on[i], off[i]) > maxDiff(on[best], off[best])) best = i;
        assert(maxDiff(on[best], off[best]) >= 2,
            format("5b premise: G2's corner draws no dot (%s -> %s)", off[best].c, on[best].c));
        immutable double[3] vpal = [0.38, 0.62, 0.92];
        bool disc = false;
        foreach (k; 0 .. 3) {
            immutable double d = litZ(vpal[k], r.vp, kGain);
            immutable double Z = (off[best].c[k] - kFill * c1[k]) / (1 - kFill);
            immutable double pred = off[best].c[k] + (1 - kFill) * kLineAlpha * (d - Z);
            immutable double rival = kLineAlpha * d + (1 - kLineAlpha) * pred;
            if (abs(pred - rival) > 4.0) disc = true;
            assert(abs(on[best].c[k] - pred) <= 2.0,
                format("5b: G2's dot channel %d reads %d, predicted %.2f veiled by layer 1 "
                       ~ "(off %d); drawn again after it would read %.2f", k,
                       on[best].c[k], pred, off[best].c[k], rival));
        }
        assert(disc, "5b premise: the veiled and re-drawn dot agree");
    }

    // ---- 6. a mirrored NON-primary item culls through its own matrix -------
    // L3 mirrored in place (x -> -x): its fill and its dots keep facing the
    // way its polygons face, so X3 stays filled with dots and R3 stays bare.
    {
        cmdOk("layer.attr 3 scl.x -1");
        settle();
        assert(num(layerAt(3)["xform"]["scl"].array[0]) == -1.0,
            "6 precondition: layer 3 scl.x must read back -1");
        {
            auto ts = getJson("/api/tool/state");
            assert(("tool" in ts.object) is null || ts["tool"].str == "",
                "6 precondition: no tool armed: " ~ ts.toString);
        }
        double[3] mx(double[3] p) { return [-p[0], p[1], p[2]]; }
        int[2][] pts = [px(mx(centre(kX3))), px(mx(centre(kR3)))];
        auto u = under(pts, [3]);
        auto o = probe(pts);
        writefln("  6 mirrored X3 %s (under %s) R3 %s (under %s)", o[0].c, u[0].c,
                 o[1].c, u[1].c);
        assert(maxDiff(o[0], u[0]) >= 5,
            format("6: the mirrored X3 is not filled (%s over %s) — the face pass "
                   ~ "did not get layer 3's own (mirroring) matrix", o[0].c, u[0].c));
        assert(maxDiff(o[1], u[1]) <= 1,
            format("6: the mirrored reversed R3 is filled (%s over %s)", o[1].c, u[1].c));
        auto n = dotPixels([px(mx([0.45, 0.45, 0.0])), px(mx([1.6, 0.1, 0.0]))], 2);
        assert(n[0] >= kCornerDot && n[1] == 0,
            format("6: mirrored X3 corner %s px (want >= %d), R3 corner %s px (want 0)",
                   n[0], kCornerDot, n[1]));
        cmdOk("layer.attr 3 scl.x 1");
        settle();
    }

    // ---- 6b. a ROTATED non-primary item: the dot cull reads its matrix -----
    // rot.y 180 turns X3 to face -Z and R3 to face +Z; a cull reading the
    // identity instead would keep X3's corners and drop R3's.
    {
        cmdOk("layer.attr 3 rot.y 180");
        settle();
        assert(abs(num(layerAt(3)["xform"]["rot"].array[1]) - 180.0) < 1e-3,
            "6b precondition: layer 3 rot.y must read back 180");
        double[3] ry(double[3] p) { return [-p[0], p[1], -p[2]]; }
        int[2][] pts = [px(ry(centre(kX3))), px(ry(centre(kR3)))];
        auto u = under(pts, [3]);
        auto o = probe(pts);
        assert(maxDiff(o[0], u[0]) <= 1 && maxDiff(o[1], u[1]) >= 5,
            format("6b premise: turned X3 must be bare (%s over %s), turned R3 filled "
                   ~ "(%s over %s)", o[0].c, u[0].c, o[1].c, u[1].c));
        auto n = dotPixels([px(ry([0.45, 0.45, 0.0])), px(ry([1.6, 0.1, 0.0]))], 2);
        assert(n[0] == 0 && n[1] >= kCornerDot,
            format("6b: turned X3 corner %s px (want 0), turned R3 corner %s px (want "
                   ~ ">= %d) — the dot cull did not read layer 3's own matrix",
                   n[0], n[1], kCornerDot));
        cmdOk("layer.attr 3 rot.y 0");
        cmd("viewport.showVertices", `{"value":"off"}`);
    }

    // ---- 4. mode off (last): the non-primary items are the dimmed backdrop --
    // Same material, same +Z normal: X3 = round(0.45 x X2's lit value) +-1
    // (A3 of the backdrop test; the two points' specular terms differ < 0.1).
    {
        cmd("viewport.retopology", `{"value":"off"}`);
        cmd("viewport.backdropStyle", `{"value":"same"}`);
        auto o = probe([px([0.65, 0.7, 0.0]), px([-0.6, -1.2, 0.0])]);   // off R1's corner
        writefln("  4 mode off: X3 %s X2 %s", o[0].c, o[1].c);
        foreach (k; 0 .. 3)
            assert(abs(o[0].c[k] - round(0.45 * o[1].c[k])) <= 1,
                format("4: mode off, layer 3 reads %s, predicted 0.45 x the primary's %s",
                       o[0].c, o[1].c));
    }
    writeln("  rig M: cells 1-6 passed");
}

// ===========================================================================
// Rig J — a joined same-as-active backdrop in the sequence (cells 7, 9)
// ===========================================================================
// Layer 0 (background): P1. Layer 1 (primary): A in front of P1, B behind
// it, D over the empty view and E behind D (E's top-right corner under D).
private immutable Quad kJP1 = Quad("P1", [-1.0, 0.5], [1.0, 1.0], 0.0, false);
private immutable Quad kJA  = Quad("A", [-1.5, 1.0], [0.25, 0.25], 0.5, false);
private immutable Quad kJB  = Quad("B", [-0.5, 1.0], [0.25, 0.25], -0.5, false);
private immutable Quad kJD  = Quad("D", [1.5, 0.5], [0.4, 0.4], 0.5, false);
private immutable Quad kJE  = Quad("E", [1.3, 0.3], [0.25, 0.25], 0.0, false);

private Rig buildRigJ() {
    cmdOk(commandBody("scene.reset"));
    cmdOk(`{"id":"history.clear"}`);
    cmdOk(commandBody("viewport.layout", `"Single"`));
    cmdOk(commandBody("scene.loadMesh", meshJson([cast(Quad) kJP1]).toString));
    cmdOk(`{"id":"layer.add"}`);
    cmdOk(commandBody("scene.loadMesh",
        meshJson([cast(Quad) kJA, cast(Quad) kJB, cast(Quad) kJD, cast(Quad) kJE]).toString));
    auto r = frontOrtho();
    cmd("viewport.displayStyle", `{"value":"shaded"}`);
    cmd("viewport.backdropStyle", `{"value":"same"}`);
    auto L = layersJson();
    assert(L["active"].integer == 1 && jb(L["layers"].array[0]["background"]),
        "rig J: layer 1 primary, layer 0 background: " ~ L.toString);
    double[3][] pts;
    foreach (v; [kJP1, kJA, kJB, kJD, kJE]) pts ~= corners(v);
    assertInside(r, pts);
    parkPointer(r);
    return r;
}

unittest {
    auto r = buildRigJ();
    scope (exit) {
        cmdRaw(commandBody("viewport.retopology", `{"value":"off"}`));
        cmdRaw(commandBody("mesh.select", `{"mode":"vertices","indices":[]}`));
        cmdRaw("select.typeFrom polygon");
        cmdRaw("viewport.view Perspective");
    }
    int[2] px(double[3] w) { return toPx(w, r.vp); }
    cmd("viewport.retopology", `{"value":"on"}`);
    assert(jb(getJson("/api/viewport/display")["cells"].array[0]["plan"]["backdrop"]
              ["joinsItemSequence"]), "premise: the same-as-active backdrop joins");

    // ---- 7a. the background at a LOWER index draws AFTER the primary -------
    // A (in front of P1) keeps its fill over the EMPTY view — P1, drawn later
    // with no clear, fails the depth test there — and B (behind P1) reads P1.
    // c unblended from D over the empty view (1.5): A = a c + (1-a) clear,
    // 0.5 + a 1.5 + (1-a) 0.5 = 1.5; B = P1 +-1 (the same draw, rounding).
    int[2] pa = px(centre(kJA)), pb = px(centre(kJB)), pd = px([1.75, 0.75, 0.0]);   // D, off E
    auto clearU = under([pa, pb, pd], [0, 1]);
    auto p1U = under([pa, pb], [1]);
    auto o = probe([pa, pb, pd]);
    immutable c = unblend(o[2], clearU[2], kFill);
    writefln("  7a A %s B %s | clear %s P1 %s", o[0].c, o[1].c, clearU[0].c, p1U[0].c);
    assert(maxDiff(p1U[0], clearU[0]) >= 5, "7 premise: P1 is not drawn");
    foreach (k; 0 .. 3) {
        immutable double pred = kFill * c[k] + (1 - kFill) * clearU[0].c[k];
        immutable double rival = kFill * c[k] + (1 - kFill) * p1U[0].c[k];
        assert(abs(o[0].c[k] - pred) <= 1.5,
            format("7a: A channel %d reads %d, predicted %.2f = its fill over the EMPTY "
                   ~ "view (P1 drawn after it); over P1 it would read %.2f",
                   k, o[0].c[k], pred, rival));
    }
    assert(maxDiff(o[1], p1U[1]) <= 1,
        format("7a: B reads %s, predicted P1's %s (P1 drawn after, in front)",
               o[1].c, p1U[1].c));

    // ---- 9. the primary's selection follows the whole sequence (C9: s2) ----
    // Selected vertex behind P1 (B's corner) and behind the primary's own D
    // (E's corner): 0.3 sel + 0.7 x the unselected pixel (0.5 + 0.7 0.5 = 0.85
    // -> 1.5 with rounding of the blend); A's corner in front: full colour +-1.
    {
        cmdOk("select.typeFrom vertex");
        settle();
        immutable double[3] vA = [kJA.c[0] + kJA.h[0], kJA.c[1] + kJA.h[1], kJA.z];
        immutable double[3] vB = [kJB.c[0] + kJB.h[0], kJB.c[1] + kJB.h[1], kJB.z];
        immutable double[3] vE = [kJE.c[0] + kJE.h[0], kJE.c[1] + kJE.h[1], kJE.z];
        int[2][] pts = [px(vA), px(vB), px(vE)];
        auto before = probe(pts);
        cmdOk(commandBody("mesh.select", `{"mode":"vertices","indices":[2,6,14]}`));
        settle();
        auto got = probe(pts);
        writefln("  9 before %s", before);
        writefln("  9 after  %s", got);
        foreach (k; 0 .. 3)
            assert(abs(got[0].c[k] - kSel[k]) <= 1,
                format("9 control: the front vertex reads %s, not the selection colour %s",
                       got[0].c, kSel));
        foreach (i; 1 .. 3)
            foreach (k; 0 .. 3) {
                immutable double pred = kOccluded * kSel[k] + (1 - kOccluded) * before[i].c[k];
                assert(abs(got[i].c[k] - pred) <= 1.5,
                    format("9: the %s vertex channel %d reads %d, predicted %.2f = 0.3 sel "
                           ~ "+ 0.7 x the pixel without it (%d) — the selection must be "
                           ~ "drawn after the last item, depth-tested, with the occluded "
                           ~ "pass", i == 1 ? "behind-P1" : "behind-own-face", k,
                           got[i].c[k], pred, before[i].c[k]));
            }
        cmdOk(commandBody("mesh.select", `{"mode":"vertices","indices":[]}`));
        cmdOk("select.typeFrom polygon");
        settle();
        parkPointer(r);
    }

    // ---- 7b. the background at a HIGHER index draws BEFORE the primary -----
    // A = a c + (1-a) P1; B visible on its own clear = a c + (1-a) P1 too.
    {
        cmdOk("layer.reorder from:0 to:1");
        settle();
        auto L = layersJson();
        assert(L["active"].integer == 0 && jb(L["layers"].array[1]["background"]),
            "7b precondition: the primary moved to index 0, the background to 1: "
            ~ L.toString);
        auto o2 = probe([pa, pb]);
        writefln("  7b A %s B %s", o2[0].c, o2[1].c);
        foreach (i; 0 .. 2)
            foreach (k; 0 .. 3) {
                immutable double pred = kFill * c[k] + (1 - kFill) * p1U[i].c[k];
                assert(abs(o2[i].c[k] - pred) <= 1.5,
                    format("7b: %s channel %d reads %d, predicted %.2f = its fill over P1 "
                           ~ "(P1 drawn first)", i ? "B" : "A", k, o2[i].c[k], pred));
            }
        cmdOk("layer.reorder from:1 to:0");
        settle();
    }
    writeln("  rig J: cells 7 and 9 passed");
}

// ===========================================================================
// Rig N — no edit target (cell 8)
// ===========================================================================
unittest {
    cmdOk(commandBody("scene.reset"));
    cmdOk(`{"id":"history.clear"}`);
    cmdOk(commandBody("viewport.layout", `"Single"`));
    immutable Quad t = Quad("T", [-1.0, 0.5], [0.8, 0.8], 0.0, false);
    cmdOk(commandBody("scene.loadMesh", meshJson([cast(Quad) t]).toString));
    cmdOk(`{"id":"layer.add"}`);
    cmdOk(commandBody("scene.loadMesh",
        meshJson([Quad("U", [1.5, -1.0], [0.3, 0.3], 0.0, false)]).toString));
    // Selection `set` flushes the other layer out of the history, so deleting
    // the holder leaves nothing holding the target (edit_target_legality,
    // `selection_nonempty_no_target`).
    cmdOk(`{"id":"layer.select","index":0,"mode":"set"}`);
    cmdOk(`{"id":"layer.select","index":1,"mode":"set"}`);
    cmdOk(`{"id":"layer.delete","index":1}`);
    auto r = frontOrtho();
    scope (exit) {
        cmdRaw(commandBody("viewport.retopology", `{"value":"off"}`));
        cmdRaw(commandBody("viewport.backdropStyle", `{"value":"same"}`));
        cmdRaw("viewport.view Perspective");
    }
    cmd("viewport.displayStyle", `{"value":"shaded"}`);
    auto L = layersJson();
    assert(L["active"].integer == -1 && L["layers"].array.length == 1
        && jb(L["layers"].array[0]["visible"]),
        "8 precondition: one visible layer and no edit target: " ~ L.toString);
    parkPointer(r);
    // Kd: an empty surface list binds the implicit slot, `Surface.init`
    // (base 0.6 × diffuse amount 0.8); otherwise slot 0's base × diffuse.
    double base = 0.6 * 0.8;
    auto s0 = getJson("/api/model?layer=0")["surfaces"].array;
    if (s0.length > 0) base = num(s0[0]["baseColor"].array[0]) * num(s0[0]["diffuseAmount"]);
    int[2] p = toPx(centre(t), r.vp);
    cmd("viewport.backdropStyle", `{"value":"flat"}`);
    immutable Px off = probe([p])[0];
    cmd("viewport.backdropStyle", `{"value":"same"}`);
    cmd("viewport.retopology", `{"value":"on"}`);
    auto b = getJson("/api/viewport/display")["cells"].array[0]["plan"]["backdrop"];
    assert(jb(b["joinsItemSequence"]) && num(b["dim"]) == 1.0,
        "8 premise: the joined backdrop is undimmed: " ~ b.toString);
    immutable Px on = probe([p])[0];
    writefln("  8 flat off %s, same on %s (base %.2f)", off.c, on.c, base);
    // A4's relation: A + (5/3)(off - A), A the ambient part; 0.5 + (5/3) 0.5.
    immutable double A = kAmbient * base * 255.0;
    foreach (k; 0 .. 3) {
        immutable double pred = A + kGain * (off.c[k] - A);
        assert(abs(on.c[k] - pred) <= 0.5 + kGain * 0.5,
            format("8: with no edit target the layer reads %s, predicted %.2f (channel "
                   ~ "%d) = the gain-lit undimmed value — it must be drawn by the joined "
                   ~ "sequence", on.c, pred, k));
    }
    // 8b: the dots say WHICH pass drew it. The joined plan draws ordinary base
    // dots with show-vertices on; the backdrop pass never draws dots. With a
    // single layer the two passes otherwise issue the same plan (D6 undims
    // both), so the fill alone cannot tell them apart.
    {
        immutable double[3] corner = [t.c[0] + t.h[0], t.c[1] + t.h[1], t.z];
        auto n = dotPixels([toPx(corner, r.vp)], 2);
        assert(n[0] >= kCornerDot,
            format("8b: with no edit target the layer's corner draws no base dot (%s px) — "
                   ~ "it was drawn by the backdrop pass, not the joined sequence", n[0]));
        cmd("viewport.showVertices", `{"value":"off"}`);
    }
    writeln("  rig N: cell 8 passed");
}

// ===========================================================================
// Rig F — per-layer materials (cells 10, 11)
// ===========================================================================
private enum string kFixture = "two_layer_distinct_surfaces.v3d";
private immutable double[3] kRedTile = [-1.6, 0.9, 0.0];   // layer "Red" only

private double[3] baseOf(int layer) {
    auto s = getJson(format("/api/model?layer=%d", layer))["surfaces"].array;
    assert(s.length == 1, format("rig F: layer %d must carry one surface, got %s",
                                 layer, s.length));
    auto bc = s[0]["baseColor"].array;
    return [num(bc[0]), num(bc[1]), num(bc[2])];
}

private Rig buildRigF() {
    cmdOk(commandBody("scene.reset"));
    cmdOk(`{"id":"history.clear"}`);
    cmdOk(commandBody("viewport.layout", `"Single"`));
    immutable string path = buildPath(dirName(__FILE_FULL_PATH__), "fixtures", kFixture);
    cmd("file.load", format(`{"path":%s}`, JSONValue(path).toString));
    auto L = layersJson();
    auto ls = L["layers"].array;
    assert(ls.length == 2 && L["active"].integer == 1 && jb(ls[0]["background"])
        && ls[0]["name"].str == "Red" && ls[1]["name"].str == "Blue",
        "rig F: Red background at 0, Blue primary at 1: " ~ L.toString);
    immutable red = baseOf(0), blue = baseOf(1);
    assert(abs(red[0] - blue[0]) > 0.3 && abs(red[2] - blue[2]) > 0.3,
        format("rig F precondition: the two surfaces must differ: %s / %s", red, blue));
    auto r = frontOrtho();
    cmd("viewport.displayStyle", `{"value":"shaded"}`);
    cmd("viewport.backdropStyle", `{"value":"same"}`);
    parkPointer(r);
    return r;
}

unittest {
    auto r = buildRigF();
    scope (exit) {
        cmdRaw(commandBody("viewport.retopology", `{"value":"off"}`));
        cmdRaw("viewport.view Perspective");
    }
    cmd("viewport.retopology", `{"value":"on"}`);
    immutable red = baseOf(0), blue = baseOf(1);
    int[2] p = toPx(kRedTile, r.vp);
    // ---- 10. the joined background draws in ITS OWN material, both orders --
    // 255 (base K + S) from our light function at the probe (+Z, gain 5/3):
    // read 0.5 + the float evaluation 0.5 = 1.0. Order 1: Red at index 0, an
    // `after` entry; order 2: Red at index 1, a `before` entry.
    void check(string order) {
        immutable Px o = probe([p])[0];
        writefln("  10 %s: Red tile %s", order, o.c);
        foreach (k; 0 .. 3) {
            immutable double pred  = litZ(red[k], r.vp, kGain);
            immutable double rival = litZ(blue[k], r.vp, kGain);
            assert(abs(o.c[k] - pred) <= 1.0,
                format("10 (%s): the Red layer channel %d reads %d, predicted %.2f from "
                       ~ "its own base %s; the primary's base would give %.2f", order, k,
                       o.c[k], pred, red, rival));
        }
    }
    check("Red after the primary");
    // The backdrop pass binds each layer's own materials as well: a flat
    // backdrop is not joined, and is lit by the same gain under the mode.
    cmd("viewport.backdropStyle", `{"value":"flat"}`);
    assert(!jb(getJson("/api/viewport/display")["cells"].array[0]["plan"]["backdrop"]
               ["joinsItemSequence"]), "10 premise: a flat backdrop does not join");
    check("Red by the backdrop pass");
    cmd("viewport.backdropStyle", `{"value":"same"}`);
    cmdOk("layer.reorder from:0 to:1");
    settle();
    {
        auto L = layersJson();
        assert(L["active"].integer == 0 && L["layers"].array[1]["name"].str == "Red",
            "10 precondition: Red at index 1, the primary at 0: " ~ L.toString);
    }
    check("Red before the primary");
    writeln("  rig F: cell 10 passed");
}

// ---- 12. a layer that first appears UNDER the mode is uploaded ------------
// Every other rig uploads its layers with the mode off, so the backdrop pass
// already holds their buffers when the sequence first runs. Here the mode is
// on BEFORE the fixture loads: the loaded layers are new, so the Red layer's
// only upload is the backdrop pass's upkeep in a frame that runs the
// sequence. Same prediction as cell 10.
unittest {
    cmdOk(commandBody("scene.reset"));
    cmdOk(`{"id":"history.clear"}`);
    cmdOk(commandBody("viewport.layout", `"Single"`));
    auto r = frontOrtho();
    scope (exit) {
        cmdRaw(commandBody("viewport.retopology", `{"value":"off"}`));
        cmdRaw("viewport.view Perspective");
    }
    cmd("viewport.displayStyle", `{"value":"shaded"}`);
    cmd("viewport.backdropStyle", `{"value":"same"}`);
    cmd("viewport.retopology", `{"value":"on"}`);
    immutable string path = buildPath(dirName(__FILE_FULL_PATH__), "fixtures", kFixture);
    cmd("file.load", format(`{"path":%s}`, JSONValue(path).toString));
    auto L = layersJson();
    assert(L["layers"].array.length == 2 && L["active"].integer == 1
        && L["layers"].array[0]["name"].str == "Red",
        "12 precondition: Red background at 0, Blue primary at 1: " ~ L.toString);
    auto plan = getJson("/api/viewport/display")["cells"].array[0]["plan"];
    assert(jb(plan["active"]["clearDepthFirst"]) && jb(plan["backdrop"]["joinsItemSequence"]),
        "12 precondition: the load must leave the mode on and the backdrop joined: "
        ~ plan.toString);
    auto cam = getJson("/api/camera?viewport=0");
    assert(cam["viewPreset"].str == "Front",
        "12 precondition: the load must keep the Front view: " ~ cam.toString);
    parkPointer(r);
    immutable red = baseOf(0), blue = baseOf(1);
    immutable Px o = probe([toPx(kRedTile, r.vp)])[0];
    writefln("  12 Red tile loaded under the mode %s", o.c);
    foreach (k; 0 .. 3) {
        immutable double pred = litZ(red[k], r.vp, kGain);
        assert(abs(o.c[k] - pred) <= 1.0,
            format("12: the Red layer loaded under the mode reads channel %d = %d, "
                   ~ "predicted %.2f (the primary's base would give %.2f) — the layer "
                   ~ "was never uploaded", k, o.c[k], pred,
                   litZ(blue[k], r.vp, kGain)));
    }
    writeln("  rig F: cell 12 passed");
}

// ---- 11. the primary's materials are bound again after the last item -----
// The pen's filled preview reads slot 0 of the shared materials buffer and
// sets no shading or gain of its own. With Red an `after` entry — the joined
// backdrop, then a FOREGROUND item under the mode's plan — the preview must
// still read the primary's (Blue) material at gain 1: equal to a control run
// with Red hidden (no entry after the primary), +-1 for rounding, and blue in
// kind.
private enum RedAs { hidden, joined, foreground }

private int[3] penPreviewFill(RedAs red) {
    auto r = buildRigF();
    cmd("viewport.retopology", `{"value":"on"}`);
    if (red == RedAs.hidden) {
        cmd("layer.setVisible", `{"index":0,"value":false}`);
        assert(!jb(layerAt(0)["visible"]), "11 control: Red must be hidden");
    } else if (red == RedAs.foreground) {
        cmdOk(`{"id":"layer.select","index":0,"mode":"add"}`);
        cmdOk("select.typeFrom polygon");
        settle();
        auto L = layersJson();
        assert(L["active"].integer == 1 && jb(L["layers"].array[0]["foreground"]),
            "11 precondition: Red a foreground item after the Blue primary: " ~ L.toString);
    }
    immutable int[2] c = toPx([-0.5, -1.2, 0.0], r.vp);
    immutable int[2][3] tri = [[c[0] - 30, c[1] + 20], [c[0] + 30, c[1] + 20],
                               [c[0], c[1] - 30]];
    immutable int[2] centroid = [(tri[0][0] + tri[1][0] + tri[2][0]) / 3,
                                 (tri[0][1] + tri[1][1] + tri[2][1]) / 3];
    immutable Px emptyPx = probe([centroid])[0];
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
    assert(pr["status"].str == "success", "11: /api/play-events failed: " ~ pr.toString);
    waitPlaybackProcessed();
    settle();
    auto px = probe([centroid])[0];
    assert(maxDiff(px, emptyPx) >= 3,
        format("11 premise: no preview fill was drawn (read %s, empty %s)", px.c, emptyPx.c));
    cmdRaw(`tool.set "pen" off 0`);
    cmdRaw(commandBody("viewport.retopology", `{"value":"off"}`));
    if (red == RedAs.hidden)
        cmdRaw(commandBody("layer.setVisible", `{"index":0,"value":true}`));
    cmdRaw("viewport.view Perspective");
    settle();
    return px.c[0 .. 3];
}

unittest {
    immutable int[3] control = penPreviewFill(RedAs.hidden);
    immutable int[3] joined  = penPreviewFill(RedAs.joined);
    immutable int[3] fgItem  = penPreviewFill(RedAs.foreground);
    writefln("  11 pen preview fill: Red hidden %s, joined after the primary %s, "
             ~ "a foreground item after it %s", control, joined, fgItem);
    assert(control[2] - control[0] >= 10,
        format("11 premise: the control preview %s is not in the primary's blue "
               ~ "material", control));
    foreach (k; 0 .. 3)
        assert(abs(joined[k] - control[k]) <= 1,
            format("11: the pen preview reads %s with Red drawn after the primary and %s "
                   ~ "without it — the primary's materials were not bound again after "
                   ~ "the last item", joined, control));
    foreach (k; 0 .. 3)
        assert(abs(fgItem[k] - control[k]) <= 1,
            format("11: the pen preview reads %s after a foreground item and %s without "
                   ~ "it — the item left its shading, gain or materials on the shared "
                   ~ "lit program", fgItem, control));
    writeln("  rig F: cell 11 passed");
}
