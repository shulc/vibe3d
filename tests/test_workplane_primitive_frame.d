// Task 7139 (item 1, gap 184): under a pinned work plane a primitive lands on
// the ray of the pixel that placed it. Law: doc/measured_laws.md §23 — the
// placement point is computed in PLANE-LOCAL view space (local ray, local
// principal plane through the local focus) and written to the channels; the
// generator maps `O + B*c`. Captured cells c-psp-cyl-drag / c-psp-cube-drag in
// tests/fixtures/workplane_align_and_primitive_placement.json (`placement`).
//
// PERSPECTIVE on purpose: in an orthographic view that turns with the plane
// the world composition and the local law coincide on screen (CAP-4), so only
// perspective separates them. Rig: default cube, default camera, placing pixel
// p = projection of the world point (0.25, 0.25, 0.5) on the +Z face.
//
// Order (druntime stops at the first red): C0 identity-plane controls
// (cylinder press ray; box centre ray), the discrimination floor (the world
// composition misses the ray by >= 0.05 on this rig), then C — the named reds.

import create_law_helpers : V3, command, number;
import drag_helpers : Vec3, Viewport, viewportFromCameraMatrices, projectToWindow,
                      pixelRay, rayDistance, dot, buildDragLog, playAndWait;
import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.conv : to;
import std.format : format;
import std.json : JSONValue, JSONType;
import std.math : abs;

void main() {}

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

private Vec3 toLocalD(in Plane p, Vec3 w) { return Vec3(dot(w, p.x), dot(w, p.y), dot(w, p.z)); }
private Vec3 toWorldP(in Plane p, Vec3 l) { return p.o + p.x * l.x + p.y * l.y + p.z * l.z; }
private float comp(Vec3 v, int i) { return i == 0 ? v.x : i == 1 ? v.y : v.z; }
private int argmaxAbs(Vec3 v) {
    float a = abs(v.x), b = abs(v.y), c = abs(v.z);
    return (a >= b && a >= c) ? 0 : (b >= c ? 1 : 2);
}
private string s(Vec3 v) { return format("(%.5f, %.5f, %.5f)", v.x, v.y, v.z); }

private Vec3 cameraFocus() {
    auto j = getJson("/api/camera");
    return Vec3(cast(float)number(j["focus"]["x"]), cast(float)number(j["focus"]["y"]),
                cast(float)number(j["focus"]["z"]));
}

/// Default cube and camera, auto plane; with `pinned`, the +Z face (reference
/// face 0) selected and the plane aligned to it.
private void rig(bool pinned) {
    auto r = postJson("/api/command", commandBody("scene.reset", "{}"));
    assert(r["status"].str == "ok", "scene reset failed: " ~ r.toString);
    command("history.clear");
    command("workplane.reset");
    auto m = getJson("/api/model");
    assert(m["vertices"].array.length == 8,
        format("rig: default scene has %d vertices, expected the 8-vertex cube",
               m["vertices"].array.length));
    if (!pinned) return;
    int face = -1;
    foreach (fi, f; m["faces"].array) {
        bool top = f.array.length == 4;
        foreach (vi; f.array)
            if (abs(number(m["vertices"].array[cast(size_t)vi.integer].array[2]) - 0.5) > 1e-5)
                top = false;
        if (top) face = cast(int)fi;
    }
    assert(face >= 0, "rig: no +Z face on the default cube");
    command(commandBody("mesh.select", format(`{"mode":"polygons","indices":[%d]}`, face)));
    command("workplane.alignToSelection");
    auto p = readPlane();
    assert(abs(p.o.z - 0.5f) < 1e-5f && abs(p.y.z - 1.0f) < 1e-5f,
        format("rig: the aligned plane is O %s normal %s, expected O (0,0,0.5) normal +Z",
               s(p.o), s(p.y)));
}

private int[2] pixelOf(Vec3 world) {
    auto vp = viewportFromCameraMatrices();
    assert(vp.proj[15] == 0.0f, "rig: the witness camera must be perspective");
    float px, py;
    assert(projectToWindow(world, vp, px, py), "rig: the placing point is behind the camera");
    return [cast(int)(px + 0.5f), cast(int)(py + 0.5f)];
}

private void drag(int[2] a, int[2] b, uint mods = 0) {
    auto vp = viewportFromCameraMatrices();
    playAndWait(buildDragLog(vp.x, vp.y, vp.width, vp.height,
                             a[0], a[1], b[0], b[1], 8, mods), testBaseUrl);
}

private Vec3 channels(string tool) {
    float g(string n) {
        auto r = postJson("/api/command", "tool.attr " ~ tool ~ " " ~ n ~ " ?");
        assert(r["status"].str == "ok", "attribute query failed: " ~ r.toString);
        return cast(float)number(r["value"]);
    }
    return Vec3(g("cenX"), g("cenY"), g("cenZ"));
}

/// Commit `tool` and return the world bbox centre of the vertices it added.
private Vec3 commitCentre(string tool, size_t floor, string cell) {
    command("tool.set " ~ tool ~ " off");
    auto v = getJson("/api/model")["vertices"].array;
    assert(v.length >= 8 + floor,
        format("%s: population floor %d new vertices, got %d", cell, floor, v.length - 8));
    Vec3 lo = Vec3(float.max, float.max, float.max), hi = Vec3(-float.max, -float.max, -float.max);
    foreach (e; v[8 .. $]) {
        Vec3 q = Vec3(cast(float)number(e.array[0]), cast(float)number(e.array[1]),
                      cast(float)number(e.array[2]));
        if (q.x < lo.x) lo.x = q.x; if (q.y < lo.y) lo.y = q.y; if (q.z < lo.z) lo.z = q.z;
        if (q.x > hi.x) hi.x = q.x; if (q.y > hi.y) hi.y = q.y; if (q.z > hi.z) hi.z = q.z;
    }
    return (lo + hi) * 0.5f;
}

private double offRay(Vec3 world, int[2] px) {
    auto vp = viewportFromCameraMatrices();
    Vec3 o, d;
    pixelRay(px[0], px[1], vp, o, d);
    return rayDistance(world, o, d);
}

private enum Vec3 kPlacing = Vec3(0.25f, 0.25f, 0.5f);

unittest {
    // ---- C0: identity-plane controls (green before and after the fix) ----
    rig(false);
    immutable int[2] p = pixelOf(kPlacing);
    immutable int[2] p2 = [p[0] + 40, p[1] + 12];
    command("tool.set prim.cylinder");
    drag(p, p2);
    Vec3 cyl0 = commitCentre("prim.cylinder", 8, "C0 cylinder");
    double d0 = offRay(cyl0, p);
    assert(d0 <= 1e-3,
        format("identity-plane control: cylinder off its press ray (d_perp %.5f, centre %s)",
               d0, s(cyl0)));

    // C0-box: our box centre lies on the PRESS ray under the Ctrl (uniform)
    // gesture — the ray the pinned cell below is held to.
    rig(false);
    command("tool.set prim.cube");
    drag(p, p2, 64);
    Vec3 box0 = commitCentre("prim.cube", 8, "C0 box");
    double dbp = offRay(box0, p), dbr = offRay(box0, p2);
    assert(dbp <= 1e-3,
        format("identity-plane control: box centre on neither ray (press %.5f, release %.5f)",
               dbp, dbr));

    // ---- discrimination floor: the world composition misses the ray ----
    rig(true);
    Plane pl = readPlane();
    auto vp = viewportFromCameraMatrices();
    Vec3 back = Vec3(vp.view[2], vp.view[6], vp.view[10]);
    int wa = argmaxAbs(back);
    Vec3 n = Vec3(wa == 0 ? 1 : 0, wa == 1 ? 1 : 0, wa == 2 ? 1 : 0);
    Vec3 fw = cameraFocus();
    Vec3 ro, rd;
    pixelRay(p[0], p[1], vp, ro, rd);
    float t = dot(fw - ro, n) / dot(rd, n);
    Vec3 worldHit = ro + rd * t;
    Vec3 wlaw = toWorldP(pl, worldHit);
    double dw = offRay(wlaw, p);
    assert(dw >= 0.05,
        format("rig does not separate plane-local placement from the world "
             ~ "composition (W-law %s is %.4f off the ray)", s(wlaw), dw));

    // ---- C: the named reds ----
    command("tool.set prim.cylinder");
    drag(p, p2);
    Vec3 cen = channels("prim.cylinder");
    Vec3 cyl = commitCentre("prim.cylinder", 8, "C cylinder");
    double dc = offRay(cyl, p);
    assert(dc <= 1e-3,
        format("primitive not placed on the ray of its placing pixel under a pinned "
             ~ "plane (cylinder): d_perp %.5f, centre %s", dc, s(cyl)));
    Vec3 backL = toLocalD(pl, back);
    int al = argmaxAbs(backL);
    Vec3 focusL = toLocalD(pl, fw - pl.o);
    assert(abs(comp(cen, al) - comp(focusL, al)) <= 1e-4,
        format("placement plane is not the local principal plane through the local "
             ~ "focus: channel %d = %.5f, local focus %s", al, comp(cen, al), s(focusL)));

    rig(true);
    command("tool.set prim.cube");
    drag(p, p2, 64);
    Vec3 box = commitCentre("prim.cube", 8, "C box");
    double db = offRay(box, p);
    assert(db <= 1e-3,
        format("primitive not placed on the ray of its placing pixel under a pinned "
             ~ "plane (box): d_perp %.5f, centre %s", db, s(box)));
}
