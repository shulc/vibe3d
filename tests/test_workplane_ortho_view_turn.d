// Task 7139 (gap 187): an orthographic preset view turns with a pinned work
// plane; the perspective camera does not. Law: doc/measured_laws.md §23 and
// its 7138 addenda — C4-oa/C4-oc F1 (the plane-local focus NUMBERS are kept
// across a pin and an unpin), C4-ob T-all (every ortho preset turns), C4-of
// P-keep-local (pinned -> pinned keeps them too). Capture: toolcards
// bugfix_w17_workplane, fixture `ortho_view` in
// tests/fixtures/workplane_align_and_primitive_placement.json.
//
// Rig: default cube (+-0.5), Single layout, one cell, POST /api/camera for the
// focus and distance. The probe pixel q is chosen from MATRICES, never from a
// rendered result: a scan (8 px) for a pixel whose world-Front ray meets the
// cube (shrunk by 0.05) while the PREDICTED turned view's ray misses it (grown
// by 0.05). Predicted = basis B*preset, eye = focus' + B*back*d, focus' by F1.
//
// Order (druntime stops at the first red): P (perspective control), K (probe
// control before the pin), T (pixel, then the camera JSON matrix), F (pin
// transition), PF (pinned -> pinned), U (reset); K2 (a pick after a turn, in
// its own block); then T and U for the Top preset under a typed plane.

import create_law_helpers : command, number;
import drag_helpers : Vec3, Viewport, viewportFromCameraMatrices, pixelRay,
                      projectToWindow, cross, dot, buildDragLog, playAndWait;
import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import core.thread : Thread;
import core.time : msecs;
import std.conv : to;
import std.format : format;
import std.json : JSONType, parseJSON;
import std.math : abs;
import std.net.curl : get;

void main() {}

private enum float kDist = 3.0f;
private enum Vec3 kFocus = Vec3(0.3f, 0.2f, 0.0f);   // C4-oa's world focus

private struct Plane { Vec3 o, x, y, z; }

private Plane readPlane() {
    auto j = getJson("/api/toolpipe");
    foreach (st; j["stages"].array) {
        if (st["task"].str != "WORK") continue;
        string[string] a;
        foreach (k, v; st["attrs"].object) a[k] = v.str;
        float g(string k) { return a[k].to!float; }
        return Plane(Vec3(g("cenX"), g("cenY"), g("cenZ")),
                     Vec3(g("axisXx"), g("axisXy"), g("axisXz")),
                     Vec3(g("normalX"), g("normalY"), g("normalZ")),
                     Vec3(g("axisZx"), g("axisZy"), g("axisZz")));
    }
    assert(false, "WORK stage not found in /api/toolpipe");
}

private Vec3 bmul(in Plane p, Vec3 l) { return p.x * l.x + p.y * l.y + p.z * l.z; }
private Vec3 toWorldP(in Plane p, Vec3 l) { return p.o + bmul(p, l); }
private string s(Vec3 v) { return format("(%.5f, %.5f, %.5f)", v.x, v.y, v.z); }
private bool near(Vec3 a, Vec3 b, float t) {
    return abs(a.x - b.x) <= t && abs(a.y - b.y) <= t && abs(a.z - b.z) <= t;
}

private Vec3 focus() {
    auto j = getJson("/api/camera");
    return Vec3(cast(float)number(j["focus"]["x"]), cast(float)number(j["focus"]["y"]),
                cast(float)number(j["focus"]["z"]));
}

private void settle() { Thread.sleep(450.msecs); }

/// View matrix with rows right/up/back and eye `e` (column-major).
private float[16] viewFrom(Vec3 r, Vec3 u, Vec3 b, Vec3 e) {
    return [r.x, u.x, b.x, 0,  r.y, u.y, b.y, 0,  r.z, u.z, b.z, 0,
            -dot(r, e), -dot(u, e), -dot(b, e), 1];
}

private bool sameMat(in float[16] a, in float[16] b, float t) {
    foreach (i; 0 .. 16) if (abs(a[i] - b[i]) > t) return false;
    return true;
}

private string m(in float[16] a) { return format("%(%.5f %)", a[]); }

/// The preset's screen right/up (source/view.d `presetBasis`).
private void presetRU(string preset, out Vec3 r, out Vec3 u) {
    if (preset == "Front") { r = Vec3(1, 0, 0); u = Vec3(0, 1, 0); }
    else if (preset == "Top") { r = Vec3(1, 0, 0); u = Vec3(0, 0, -1); }
    else assert(false, "no preset basis for " ~ preset);
}

/// Predicted view of `preset` turned by `p` around world focus `f`.
private float[16] turnedView(string preset, in Plane p, Vec3 f) {
    Vec3 r, u;
    presetRU(preset, r, u);
    Vec3 tr = bmul(p, r), tu = bmul(p, u), tb = cross(tr, tu);
    return viewFrom(tr, tu, tb, f + tb * kDist);
}

private float[16] worldView(string preset, Vec3 f) {
    Vec3 r, u;
    presetRU(preset, r, u);
    Vec3 b = cross(r, u);
    return viewFrom(r, u, b, f + b * kDist);
}

private bool hitsCube(Vec3 o, Vec3 d, float h) {
    float t0 = -float.max, t1 = float.max;
    foreach (i; 0 .. 3) {
        float oi = i == 0 ? o.x : i == 1 ? o.y : o.z;
        float di = i == 0 ? d.x : i == 1 ? d.y : d.z;
        if (abs(di) < 1e-9f) { if (abs(oi) > h) return false; continue; }
        float a = (-h - oi) / di, b = (h - oi) / di;
        if (a > b) { float t = a; a = b; b = t; }
        if (a > t0) t0 = a;
        if (b < t1) t1 = b;
    }
    return t1 >= t0;
}

/// q: window pixel whose ray meets the cube under `before` and misses it
/// under `after` — the candidate nearest the centroid of all such pixels.
private int[2] chooseQ(Viewport vp, in float[16] before, in float[16] after, string cell) {
    int[2][] cands;
    for (int y = vp.y + 8; y < vp.y + vp.height - 8; y += 8)
        for (int x = vp.x + 8; x < vp.x + vp.width - 8; x += 8) {
            Viewport a = vp, b = vp;
            a.view = before; b.view = after;
            a.eye = eyeOf(before); b.eye = eyeOf(after);
            Vec3 o, d;
            pixelRay(x, y, a, o, d);
            if (!hitsCube(o, d, 0.45f)) continue;
            pixelRay(x, y, b, o, d);
            if (hitsCube(o, d, 0.55f)) continue;
            cands ~= [x, y];
        }
    assert(cands.length >= 4, format("%s: no probe pixel separates the world view "
         ~ "from the predicted turned view (%d candidates)", cell, cands.length));
    double cx = 0, cy = 0;
    foreach (c; cands) { cx += c[0]; cy += c[1]; }
    cx /= cands.length; cy /= cands.length;
    int[2] best = cands[0];
    double bd = double.max;
    foreach (c; cands) {
        double dd = (c[0] - cx) * (c[0] - cx) + (c[1] - cy) * (c[1] - cy);
        if (dd < bd) { bd = dd; best = c; }
    }
    return best;
}

private Vec3 eyeOf(in float[16] v) {
    Vec3 r = Vec3(v[0], v[4], v[8]), u = Vec3(v[1], v[5], v[9]), b = Vec3(v[2], v[6], v[10]);
    return (r * -v[12]) + (u * -v[13]) + (b * -v[14]);
}

private struct Px { int r, g, b; }

private Px probe(int wx, int wy, Viewport vp) {
    auto j = getJson(format("/api/viewport/probe?cell=0&points=%d,%d", wx - vp.x, wy - vp.y));
    assert("error" !in j, "probe failed: " ~ j.toString);
    assert(j["renders"].type == JSONType.true_, "the probed cell is not rendered");
    auto e = j["points"].array[0];
    return Px(cast(int)e["r"].integer, cast(int)e["g"].integer, cast(int)e["b"].integer);
}

private int dist(Px a, Px b) { return abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b); }

/// True when the pixel shows the cube rather than the background colour read
/// at the cell's corner. Measured on this rig: the lit cube face reads
/// (105, 105, 105) or (169, 169, 169), the background (92, 102, 107) — a
/// distance of 18 at the least. A face-on work-plane grid draws 1-px lines
/// over the background (measured (126, 127, 127) at a Top probe), so the
/// verdict is a majority over a 3x3 stencil 3 px apart: a line crosses at most
/// five of the nine samples.
private bool seesCube(int[2] q, Viewport vp) {
    settle();
    Px bg = probe(vp.x + 4, vp.y + 4, vp);
    int off = 0;
    foreach (dy; [-3, 0, 3]) foreach (dx; [-3, 0, 3])
        if (dist(probe(q[0] + dx, q[1] + dy, vp), bg) > 8) ++off;
    return off >= 6;
}

private void rig(string preset, Vec3 f) {
    auto r = postJson("/api/command", commandBody("scene.reset", "{}"));
    assert(r["status"].str == "ok", "scene reset failed: " ~ r.toString);
    command("history.clear");
    command("workplane.reset");
    command("viewport.view " ~ preset);
    r = postJson("/api/camera", format(`{"focus":{"x":%.9f,"y":%.9f,"z":%.9f},"distance":%.9f}`,
                                       f.x, f.y, f.z, kDist));
    assert(r["status"].str == "ok", "camera setup failed: " ~ r.toString);
}

/// Select the cube face whose vertices all have coordinate `axis` == +0.5, align.
private void alignToFace(int axis) {
    auto m = getJson("/api/model");
    int face = -1;
    foreach (fi, f; m["faces"].array) {
        bool all = f.array.length == 4;
        foreach (vi; f.array)
            if (abs(number(m["vertices"].array[cast(size_t)vi.integer].array[axis]) - 0.5) > 1e-5)
                all = false;
        if (all) face = cast(int)fi;
    }
    assert(face >= 0, format("rig: no face at +0.5 on axis %d", axis));
    command(commandBody("mesh.select", format(`{"mode":"polygons","indices":[%d]}`, face)));
    command("workplane.alignToSelection");
}

unittest { // P — perspective control: the camera does not move with the plane
    rig("Perspective", Vec3(0, 0, 0));
    auto before = viewportFromCameraMatrices();
    alignToFace(2);
    auto after = viewportFromCameraMatrices();
    assert(sameMat(before.view, after.view, 1e-6f) && near(focus(), Vec3(0, 0, 0), 1e-6f),
        format("perspective camera moved with the plane: %s -> %s", m(before.view), m(after.view)));
}

unittest { // Front: K, T, F, PF, U
    rig("Front", kFocus);
    auto vp = viewportFromCameraMatrices();
    // K — the probe and the matrices are what they claim before the pin.
    assert(sameMat(vp.view, worldView("Front", kFocus), 1e-5f),
        format("rig: camera JSON view matrix is not the world Front view: %s", m(vp.view)));
    alignToFace(2);
    Plane p = readPlane();
    immutable Vec3 f1 = toWorldP(p, kFocus);                 // F1: numbers kept
    auto predicted = turnedView("Front", p, f1);
    command("workplane.reset");
    int[2] q = chooseQ(vp, worldView("Front", kFocus), predicted, "Front");
    import std.stdio : writefln;
    writefln("q(Front) = (%d, %d); plane O %s X %s Y %s Z %s", q[0], q[1],
             s(p.o), s(p.x), s(p.y), s(p.z));
    assert(seesCube(q, vp), format("rig: probe q (%d, %d) does not see the cube before the pin", q[0], q[1]));

    // T — the pin turns the Front view.
    alignToFace(2);
    assert(!seesCube(q, vp),
        format("ortho Front view did not turn with the pinned plane (pixel %d, %d)", q[0], q[1]));
    auto turned = viewportFromCameraMatrices();
    assert(sameMat(turned.view, predicted, 1e-4f),
        format("camera JSON view matrix is not the plane-local front view:\n  got  %s\n  want %s",
               m(turned.view), m(predicted)));

    // F — the pin transition (C4-oa F1).
    assert(near(focus(), f1, 1e-4f),
        format("ortho focus transition differs from the captured rule (pin): %s, expected %s",
               s(focus()), s(f1)));

    // PF — pinned -> pinned (C4-of P-keep-local).
    alignToFace(1);
    Plane p2 = readPlane();
    assert(!near(p2.o, p.o, 1e-3f), "rig: the +Y face gave the same plane origin");
    assert(near(focus(), toWorldP(p2, kFocus), 1e-4f),
        format("ortho focus transition differs from the captured rule (pinned to pinned): "
             ~ "%s, expected %s", s(focus()), s(toWorldP(p2, kFocus))));

    // U — the reset brings the world view back (C4-oc F1).
    command("workplane.reset");
    auto back_ = viewportFromCameraMatrices();
    assert(near(focus(), kFocus, 1e-4f) && seesCube(q, vp)
        && sameMat(back_.view, worldView("Front", kFocus), 1e-4f),
        format("ortho view did not return after the plane reset: focus %s, view %s",
               s(focus()), m(back_.view)));
}

unittest { // K2 — a pick after the turn reads an ID buffer rasterised under it
    // The vertex-mode ID buffer is made valid under the WORLD view first (a
    // hover in vertex mode), then the plane is pinned by a typed edit, which
    // changes neither the mesh nor the selection — so the camera is the only
    // term that can tell the picker its buffer is stale.
    rig("Front", kFocus);
    command("select.typeFrom vertex");
    command(commandBody("mesh.select", `{"mode":"vertices","indices":[]}`));
    auto world = viewportFromCameraMatrices();
    int hx = world.x + world.width / 2, hy = world.y + world.height / 2;
    playAndWait(format(`{"t":0.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":1,"yrel":0,"state":0,"mod":0}`
                       ~ "\n", hx, hy), testBaseUrl);
    settle();
    command("workplane.edit cenX:0.4 cenY:0 cenZ:0 rotX:30 rotY:40 rotZ:0");
    settle();
    auto turned = viewportFromCameraMatrices();
    assert(!sameMat(turned.view, world.view, 1e-3f), "rig: the typed pin did not turn the view");
    auto mdl = getJson("/api/model");
    Vec3 back = Vec3(turned.view[2], turned.view[6], turned.view[10]);
    int best = -1;
    float bestDepth = -float.max, bx, by;
    foreach (i, v; mdl["vertices"].array) {
        Vec3 w = Vec3(cast(float)number(v.array[0]), cast(float)number(v.array[1]),
                      cast(float)number(v.array[2]));
        float px, py, ox, oy;
        if (!projectToWindow(w, turned, px, py)) continue;
        if (px < turned.x + 10 || py < turned.y + 10 || px > turned.x + turned.width - 10
            || py > turned.y + turned.height - 10) continue;
        // The same pixel must NOT show this vertex in the world view, or a
        // stale buffer would answer correctly by accident.
        if (projectToWindow(w, world, ox, oy) && abs(ox - px) + abs(oy - py) < 20) continue;
        if (dot(w, back) > bestDepth) { bestDepth = dot(w, back); best = cast(int)i; bx = px; by = py; }
    }
    assert(best >= 0, "rig: no cube vertex separates the turned view from the world view");
    int cx = cast(int)(bx + 0.5f), cy = cast(int)(by + 0.5f);
    playAndWait(buildDragLog(turned.x, turned.y, turned.width, turned.height,
                             cx, cy, cx, cy, 1), testBaseUrl);
    auto sel = parseJSON(cast(string)get(testBaseUrl() ~ "/api/selection"));
    int[] ids;
    foreach (v; sel["selectedVertices"].array) ids ~= cast(int)v.integer;
    assert(ids == [best],
        format("picker served an ID buffer from before the turn: clicked vertex %d "
             ~ "at (%d, %d), selected %s", best, cx, cy, ids));
    command("workplane.reset");
}

unittest { // Top: T and U (C4-ob T-all) under a TYPED oblique plane (C4-od D-turn)
    // A face-aligned plane cannot separate the Top views: the cube stays
    // centred on the plane's in-plane axes and the Top view hides the normal,
    // so the world and the turned projections are the same square. A typed
    // oblique, off-centre plane draws the cube obliquely.
    immutable Vec3 ft = Vec3(0.3f, 0.0f, 0.2f);
    enum typed = "workplane.edit cenX:0.4 cenY:0 cenZ:0 rotX:30 rotY:40 rotZ:0";
    rig("Top", ft);
    auto vp = viewportFromCameraMatrices();
    command(typed);
    Plane p = readPlane();
    auto predicted = turnedView("Top", p, toWorldP(p, ft));
    command("workplane.reset");
    int[2] q = chooseQ(vp, worldView("Top", ft), predicted, "Top");
    assert(seesCube(q, vp), format("rig: Top probe q (%d, %d) does not see the cube", q[0], q[1]));
    command(typed);
    assert(!seesCube(q, vp),
        format("ortho Top view did not turn with the pinned plane (pixel %d, %d)", q[0], q[1]));
    assert(sameMat(viewportFromCameraMatrices().view, predicted, 1e-4f),
        "camera JSON view matrix is not the plane-local top view");
    command("workplane.reset");
    assert(seesCube(q, vp) && near(focus(), ft, 1e-4f),
        format("ortho Top view did not return after the plane reset: focus %s", s(focus())));
}
