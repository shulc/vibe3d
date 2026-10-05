// A create click over a BACKGROUND surface with the surface constraint on,
// against tests/fixtures/create_click_surface.json (task 9404). Role law: the
// vertex tool's FREE point reads the surface — the background hit on the view
// ray through the click's quantised plane point q (parallel in ortho, from the
// eye in perspective), not re-quantised, offset along the hit normal after it,
// then the snap replacing all three channels; a primitive's PRESS point (box
// corner, sphere centre) stays the plane point.
//
// Every vertex rig clicks the same pixel twice: first with the constraint's
// `handle` off — the plane point q, the control (and the handle-off cell) —
// then with it on. A ray cell asserts the surface point within 1e-5 of the ray
// from OUR eye through that q, and at least 1e-3 off the pixel's own ray (the
// raw-pixel-ray law); a top-view cell asserts the
// in-plane channels against q to 1e-5. Heights are the reference's depth read:
// the cell's own tolerance, floor 2e-3 (findings: K-C2 PF-5).

import drag_helpers : Vec3, Viewport, buildDragLog, fetchCamera, pixelRay,
    playAndWait, viewportFromCameraMatrices;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import symmetry_selection_helpers : num;
import pen_rig_helpers : clickPixels, penCameraAt, penCommand, penSceneEmpty, readVerts,
    worldPixel;
import std.algorithm : canFind;
import std.array : join;
import std.format : format;
import std.json : JSONValue, parseJSON;
import std.math : PI, abs, cos, round, sin, sqrt, tan;
import std.process : environment;
import std.string : split;

void main() {}

private enum double kRay = 1e-5;

private double[3] arr3(JSONValue a) { return [num(a.array[0]), num(a.array[1]), num(a.array[2])]; }
private Vec3 v3(double[3] a) { return Vec3(cast(float)a[0], cast(float)a[1], cast(float)a[2]); }
private double[3] d3(Vec3 v) { return [v.x, v.y, v.z]; }
private double[3] sub(double[3] a, double[3] b) { return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]; }
private double dot3(double[3] a, double[3] b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
private double len(double[3] a) { return sqrt(dot3(a, a)); }

/// Distance from `p` to the line through `o` along `d`.
private double rayDist(double[3] p, double[3] o, double[3] d) {
    const u = 1 / len(d);
    const double[3] n = [d[0] * u, d[1] * u, d[2] * u];
    const w = sub(p, o), t = dot3(w, n);
    return len([w[0] - n[0] * t, w[1] - n[1] * t, w[2] - n[2] * t]);
}

/// World = Rx(deg) * frame (the work plane pinned at the origin).
private double[3] rotX(double[3] l, double deg) {
    const a = deg * PI / 180;
    return [l[0], cos(a) * l[1] - sin(a) * l[2], sin(a) * l[1] + cos(a) * l[2]];
}

private struct Rig {
    string name;
    JSONValue view;
    double pinDeg = 0;
}

/// Empty foreground, the background sphere, the camera, the constraint on
/// (geometry off) with `offset`; the tool `tool` armed.
private void rig(const ref Rig r, string tool, double offset, string[] extra = null) {
    const v = r.view;
    const persp = v["projection"].str == "perspective";
    penSceneEmpty(persp ? "Perspective" : v["preset"].str);
    penCommand("layer.add name:Bg");
    penCommand("prim.sphere cenX:0 cenY:1 cenZ:0 sizeX:1 sizeY:1 sizeZ:1 sides:64 segments:32");
    penCommand("layer.setVisible index:1 value:true");
    penCommand("layer.select index:0");
    foreach (c; extra) {
        auto x = postJson("/api/command", c);
        assert(x["status"].str == "ok", r.name ~ " rig: " ~ c ~ " -> " ~ x.toString);
    }
    if (r.pinDeg != 0)
        penCommand(format("workplane.edit cenX:0 cenY:0 cenZ:0 rotX:%.9f", r.pinDeg));
    const f = arr3(v["focus"]);
    if (persp) {
        // Straight down, exactly (the orbit chart clamps at 89 degrees); the
        // distance as recorded, or OUR distance for the record's scale
        // (`penCameraAt`'s perspective law).
        const dist = "distance" in v.object ? num(v["distance"])
                   : fetchCamera().height / (1.6 * num(v["px_per_m"]) * tan(PI / 8));
        auto c = postJson("/api/camera", format(`{"orientation":[1,0,0, 0,0,-1, 0,1,0],`
            ~ `"focus":{"x":%.9f,"y":%.9f,"z":%.9f},"distance":%.9f}`, f[0], f[1], f[2], dist));
        assert(c["status"].str == "ok", r.name ~ " rig: camera " ~ c.toString);
    } else {
        penCameraAt(v3(f), num(v["px_per_m"]));
    }
    auto g = getJson("/api/viewport/display")["cells"].array[0]["grid"];
    foreach (k; [["q", "subStep"], ["grid", "size"]])
        if (k[0] in v.object)
            assert(abs(num(g[k[1]]) - num(v[k[0]])) <= 1e-6 * num(v[k[0]]),
                format("%s rig: our %s %.9g, the cell's %s", r.name, k[0], num(g[k[1]]), num(v[k[0]])));
    penCommand("tool.set " ~ tool);
    penCommand("tool.pipe.attr constrain enabled true");
    penCommand("tool.pipe.attr constrain geometry off");
    penCommand(format("tool.pipe.attr constrain offset %.9f", offset));
    handle(true);
}

private void handle(bool on) {
    penCommand("tool.pipe.attr constrain handle " ~ (on ? "true" : "false"));
    foreach (st; getJson("/api/toolpipe")["stages"].array)
        if (st["task"].str == "CONS") {
            assert(st["attrs"]["enabled"].str == "true"
                && st["attrs"]["handle"].str == (on ? "true" : "false"),
                "rig: the constraint did not read back as written: " ~ st.toString);
            return;
        }
    assert(false, "rig: no CONS stage in /api/toolpipe");
}

private string within(string cell, string what, double[3] got, double[3] want, double tol,
                      const(int)[] channels = [0, 1, 2]) {
    foreach (i; channels)
        if (!(abs(got[i] - want[i]) <= tol))
            return format("%s: %s %(%.6f %), expected %(%.6f %) (channel %d, tol %g)",
                          cell, what, got[], want[], i, tol);
    return null;
}

/// On an armed vertex rig: a handle-off click (q) then a handle-on click at
/// the same pixel; returns the foreground vertices [q, surface].
private Vec3[] vertexPair(int[2] px) {
    handle(false);
    clickPixels(px);
    handle(true);
    clickPixels(px);
    penCommand("tool.set prim.vertex off");
    return readVerts();
}

/// The pixel whose ray meets the horizontal plane through `q` nearest `q`
/// (within 0.45 q on both in-plane channels, so the click's q IS `q`): our
/// pixel is not the record's, and at a coarse scale a rounded projection can
/// fall into the neighbouring q cell.
private int[2] aimQ(double[3] q, double quantum) {
    const p0 = worldPixel(v3(q));
    auto vp = viewportFromCameraMatrices();
    int[2] best; double bd = double.infinity;
    foreach (dy; -1 .. 2) foreach (dx; -1 .. 2) {
        Vec3 o, d;
        pixelRay(p0[0] + dx, p0[1] + dy, vp, o, d);
        const t = (q[1] - o.y) / d.y;
        const e = abs(o.x + d.x * t - q[0]) > abs(o.z + d.z * t - q[2])
                ? abs(o.x + d.x * t - q[0]) : abs(o.z + d.z * t - q[2]);
        if (e < bd) { bd = e; best = [p0[0] + dx, p0[1] + dy]; }
    }
    assert(bd < 0.45 * quantum, format("rig: no pixel near %s hits within 0.45 q (%.4f)", q, bd));
    return best;
}

/// A ray cell: the surface point on OUR eye ray through q (1e-5), off the
/// pixel ray (>= 1e-3), and against the captured point to the cell's
/// tolerance when the camera is the captured one.
private string rayCell(string name, JSONValue c, Rig r) {
    rig(r, "prim.vertex", num(c["offset"]));
    const px = "q_point" in c.object ? aimQ(arr3(c["q_point"]), num(r.view["q"]))
                                      : worldPixel(v3(arr3(c["aim_world"])));
    auto vs = vertexPair(px);
    if (vs.length != 2) return format("%s: %d vertices, expected 2", name, vs.length);
    const q = d3(vs[0]), s = d3(vs[1]);
    if ("q_point" in c.object)
        if (auto m = within(name, "control q", q, arr3(c["q_point"]), kRay)) return m;
    const eye = d3(fetchCamera().eye);
    const dq = rayDist(s, eye, sub(q, eye));
    auto vp = viewportFromCameraMatrices();
    Vec3 po, pd;
    pixelRay(px[0], px[1], vp, po, pd);
    const dp = rayDist(s, d3(po), d3(pd));
    if (!(dp >= 1e-3))
        return format("%s: surface point %(%.6f %) is %.2e off the pixel's own ray (the "
                      ~ "q-ray law puts it >= 1e-3 off)", name, s[], dp);
    if (!(dq <= kRay))
        return format("%s: surface point %(%.6f %) is %.2e off the eye ray through q %(%.6f %)",
                      name, s[], dq, q[]);
    if ("expect_world" in c.object)
        return within(name, "surface point", s, arr3(c["expect_world"]), num(c["height_tol"]));
    // No captured camera: the point must still be ON the background (radius 1
    // about (0,1,0), a 64 x 32 facet model).
    const rad = len(sub(s, [0.0, 1.0, 0.0]));
    if (!(abs(rad - 1) <= 2.5e-3))
        return format("%s: surface point %(%.6f %) at radius %.6f, not on the background", name,
                      s[], rad);
    return null;
}

/// A base drag: press on the pixel whose plane hit rounds to `q_point`,
/// release `drag_px` (or over `release_aim_world`) later; the dragged point D
/// read back from the armed tool's channels (box corner 2, the radial radii,
/// the torus ring radius) against the cell's law.
private string baseDragCell(string name, JSONValue c, Rig r) {
    const fam = c["family"].str;
    const tool = fam == "box" ? "prim.cube" : "prim." ~ fam;
    rig(r, tool, num(c["offset"]));
    if (!c["handle"].boolean) handle(false);
    if (!c["constraint_enabled"].boolean) penCommand("tool.pipe.attr constrain enabled false");
    auto vp = viewportFromCameraMatrices();
    // Pq = the cell's q point, or q of our own press ray's hit on the base plane y 0.
    double[3] planeHit(int[2] px, double y) {
        Vec3 o, dir;
        pixelRay(px[0], px[1], vp, o, dir);
        const t = (y - o.y) / dir.y;
        return [o.x + dir.x * t, y, o.z + dir.z * t];
    }
    const qs = num(r.view["q"]);
    const p0 = "q_point" in c.object ? aimQ(arr3(c["q_point"]), qs) : worldPixel(v3(arr3(c["press_aim_world"])));
    double[3] q = "q_point" in c.object ? arr3(c["q_point"]) : planeHit(p0, 0);
    foreach (ref x; q) x = round(x / qs) * qs;
    int[2] p1;
    if ("drag_px" in c.object) {
        // The cell's travel is the record's screen travel: our top view must
        // turn +x to the right and +z down, as the record's did.
        const ox = worldPixel(v3([q[0] + 0.2, q[1], q[2]])), oz = worldPixel(v3([q[0], q[1], q[2] + 0.2]));
        assert(ox[0] > p0[0] && abs(ox[1] - p0[1]) <= 1 && oz[1] > p0[1] && abs(oz[0] - p0[0]) <= 1,
            name ~ " rig: our top view does not map +x right and +z down");
        p1 = [p0[0] + cast(int)c["drag_px"].array[0].integer, p0[1] + cast(int)c["drag_px"].array[1].integer];
    } else p1 = worldPixel(v3(arr3(c["release_aim_world"])));
    auto cam = fetchCamera();
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height, p0[0], p0[1], p1[0], p1[1], 8));
    double attr(string a) {
        auto x = postJson("/api/command", "tool.attr " ~ tool ~ " " ~ a ~ " ?");
        assert(x["status"].str == "ok", name ~ ": " ~ x.toString);
        return num(x["value"]);
    }
    const double[3] cen = [attr("cenX"), attr("cenY"), attr("cenZ")];
    if (fam == "torus") {
        const R = attr("majorRadius");
        penCommand("tool.set " ~ tool ~ " off");
        if (auto m = within(name, "centre (the press)", cen, q, kRay)) return m;
        const want = num(c["expect_major_radius"]);
        return abs(R - want) <= num(c["tol"]) ? null
            : format("%s: ring radius %.6f, expected |D - Pq| %.6f (tol %g)", name, R, want, num(c["tol"]));
    }
    const double sx = attr("sizeX"), sz = attr("sizeZ");
    penCommand("tool.set " ~ tool ~ " off");
    if (fam != "box") {
        if (auto m = within(name, "centre (the press)", cen, q, kRay)) return m;
        const e = c["expect_radii_xz"].array;
        return within(name, "radii |D - Pq|", [sx, 0, sz], [num(e[0]), 0, num(e[1])], num(c["tol"]), [0, 2]);
    }
    // Corner 2 lies on the release side of corner 1 = Pq.
    const double[3] aim = "expect_xz" in c.object
        ? [num(c["expect_xz"].array[0]), q[1], num(c["expect_xz"].array[1])] : arr3(c["release_aim_world"]);
    const double gx = aim[0] > q[0] ? 1 : -1, gz = aim[2] > q[2] ? 1 : -1;
    const double[3] c1 = [cen[0] - gx * sx / 2, cen[1], cen[2] - gz * sz / 2],
                    d  = [cen[0] + gx * sx / 2, cen[1], cen[2] + gz * sz / 2];
    if (auto m = within(name, "corner 1 (the press)", c1, q, kRay)) return m;
    if ("expect_xz" in c.object)
        return within(name, "corner 2", d, aim, num(c["tol"]), [0, 2]);
    // Straight down: T = Pq + (R - P) from our own rays on the base plane;
    // the corner's xz is the eye-ray-through-T's background hit's.
    const P = planeHit(p0, q[1]), R = planeHit(p1, q[1]);
    const double[3] T = [q[0] + R[0] - P[0], q[1], q[2] + R[2] - P[2]];
    const eye = d3(cam.eye), ray = sub(T, eye);
    // The ray's point over the corner's xz: cross-trace in xz, then that point on the background.
    const hl = ray[0] * ray[0] + ray[2] * ray[2];
    const s = ((d[0] - eye[0]) * ray[0] + (d[2] - eye[2]) * ray[2]) / hl;
    const double[3] on = [eye[0] + ray[0] * s, eye[1] + ray[1] * s, eye[2] + ray[2] * s];
    const cross = len([d[0] - on[0], 0, d[2] - on[2]]);
    if (!(cross <= kRay))
        return format("%s: corner 2 xz (%.6f, %.6f) is %.2e off the eye ray through T %(%.6f %)",
                      name, d[0], d[2], cross, T[]);
    const rad = len(sub(on, [0.0, 1.0, 0.0]));
    return abs(rad - 1) <= 2.5e-3 ? null
        : format("%s: the eye ray through T %(%.6f %) reaches corner 2's xz at %(%.6f %), radius %.6f: "
                 ~ "not the background hit (the plane branch sits at radius %.3f)", name, T[], on[],
                 rad, len(sub(T, [0.0, 1.0, 0.0])));
}

unittest {
    auto fx = parseJSON(import("fixtures/create_click_surface.json"));
    // VIBE3D_CELL=<name>[,<name>...] runs only those cells (mutation drills).
    // (`"".split(",")` is EMPTY, not [""]: test the variable, not the split.)
    const sel = environment.get("VIBE3D_CELL", "");
    const only = sel.length ? sel.split(",") : null;
    bool wanted(string name) { return only is null || only.canFind(name); }
    string[] fails;
    int ran;
    JSONValue cell(string n) { return fx["cells"][n]; }
    Rig rigOf(string n) {
        const c = cell(n);
        Rig r = Rig(n, fx["views"][c["view"].str]);
        if ("pin_rot_x_deg" in r.view.object) r.pinDeg = num(r.view["pin_rot_x_deg"]);
        return r;
    }
    void note(string m) { if (m) fails ~= m; }

    // ---- must stay green: a primitive's PRESS point never reads the surface.
    foreach (n; ["box-press-plane", "box-press-plane-persp"]) {
        if (!wanted(n)) continue;
        const c = cell(n);
        auto r = rigOf(n);
        rig(r, "prim.cube", 0);
        const p = worldPixel(v3(arr3(c["aim_world"])));
        auto cam = fetchCamera();
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                 p[0], p[1], p[0] + 40, p[1] + 40, 4, 0, 1));
        penCommand("tool.set prim.cube off");
        const want = arr3(c["expect_world"]);
        double[3] best; double bd = double.infinity;
        foreach (v; readVerts()) {
            const d = len(sub(d3(v), want));
            if (d < bd) { bd = d; best = d3(v); }
        }
        note(within(n, "press corner", best, want, 1e-4));
        ++ran;
    }
    if (wanted("sphere-press-plane")) {
        enum n = "sphere-press-plane";
        const c = cell(n);
        auto r = rigOf(n);
        rig(r, "prim.sphere", 0);
        const p = worldPixel(v3(arr3(c["aim_world"])));
        auto cam = fetchCamera();
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                 p[0], p[1], p[0] + 40, p[1] + 40, 4, 0, 1));
        double[3] got;
        foreach (i, a; ["cenX", "cenY", "cenZ"]) {
            auto x = postJson("/api/command", "tool.attr prim.sphere " ~ a ~ " ?");
            assert(x["status"].str == "ok", n ~ ": " ~ x.toString);
            got[i] = num(x["value"]);
        }
        penCommand("tool.set prim.sphere off");
        note(within(n, "centre", got, arr3(c["expect_world"]), 1e-4));
        ++ran;
    }

    // ---- top view: the handle-off control, the surface point, the offset.
    if (wanted("vertex-surface-top") || wanted("vertex-surface-offset")
        || wanted("vertex-surface-handle-off")) {
        const ct = cell("vertex-surface-top"), co = cell("vertex-surface-offset");
        auto r = rigOf("vertex-surface-top");
        rig(r, "prim.vertex", 0);
        const px = worldPixel(v3(arr3(ct["aim_world"])));
        handle(false);
        clickPixels(px);
        handle(true);
        clickPixels(px);
        penCommand(format("tool.pipe.attr constrain offset %.9f", num(co["offset"])));
        clickPixels(px);
        penCommand("tool.set prim.vertex off");
        auto vs = readVerts();
        assert(vs.length == 3, format("top rig: %d vertices, expected 3", vs.length));
        const q = d3(vs[0]), s = d3(vs[1]), o = d3(vs[2]);
        if (wanted("vertex-surface-handle-off")) {
            note(within("vertex-surface-handle-off", "handle-off click",
                        q, arr3(cell("vertex-surface-handle-off")["expect_world"]), kRay));
            ++ran;
        }
        if (wanted("vertex-surface-top")) {
            note(within("vertex-surface-top", "in-plane", s, arr3(ct["q_point"]), kRay, [0, 2]));
            note(within("vertex-surface-top", "height", s, arr3(ct["expect_world"]),
                        num(ct["height_tol"]), [1]));
            ++ran;
        }
        if (wanted("vertex-surface-offset")) {
            // The offset is 0.1 along the hit normal of the SAME q-ray hit:
            // offsetting before a quantum would move it off that length.
            const d = sub(o, s), want = num(co["offset"]);
            if (!(abs(len(d) - want) <= kRay))
                note(format("vertex-surface-offset: offset vector %(%.6f %) has length %.6f, "
                    ~ "expected %.6f from the surface point %(%.6f %)", d[], len(d), want, s[]));
            const nrm = sub(s, [0.0, 1.0, 0.0]);
            if (!(dot3(d, nrm) / (len(d) * len(nrm)) >= cos(3 * PI / 180)))
                note(format("vertex-surface-offset: the offset %(%.6f %) is not along the "
                    ~ "surface normal %(%.6f %)", d[], nrm[]));
            note(within("vertex-surface-offset", "offset point", o, arr3(co["expect_world"]),
                        num(co["height_tol"])));
            ++ran;
        }
    }

    // ---- perspective: the eye ray through q.
    foreach (n; ["vertex-surface-persp", "vertex-surface-persp-coarse-b",
                 "vertex-surface-persp-coarse-c"]) {
        if (!wanted(n)) continue;
        note(rayCell(n, cell(n), rigOf(n)));
        ++ran;
    }

    // ---- a top preset turned by a pinned plane: frame-local channels.
    if (wanted("vertex-surface-turned-top")) {
        enum n = "vertex-surface-turned-top";
        const c = cell(n);
        auto r = rigOf(n);
        rig(r, "prim.vertex", 0);
        const px = worldPixel(v3(rotX(arr3(c["aim_frame"]), r.pinDeg)));
        auto vs = vertexPair(px);
        assert(vs.length == 2, format("%s: %d vertices, expected 2", n, vs.length));
        const s = rotX(d3(vs[1]), -r.pinDeg);
        const qxz = c["q_frame_xz"].array;
        note(within(n, "frame in-plane", s, [num(qxz[0]), 0, num(qxz[1])], kRay, [0, 2]));
        note(within(n, "frame height", s, arr3(c["expect_frame"]), num(c["height_tol"]), [1]));
        note(within(n, "world point", d3(vs[1]), arr3(c["expect_world"]), num(c["height_tol"])));
        ++ran;
    }

    // ---- the snap runs LAST and replaces all three channels; no weld.
    if (wanted("vertex-surface-snap")) {
        enum n = "vertex-surface-snap";
        const c = cell(n);
        auto r = rigOf(n);
        const fg = arr3(c["foreground_vertex"]);
        rig(r, "prim.vertex", 0, [commandBody("mesh.addVertex",
            format(`{"pos":[%.9f,%.9f,%.9f]}`, fg[0], fg[1], fg[2]))]);
        const px = worldPixel(v3(arr3(c["aim_world"])));
        foreach (s; ["tool.pipe.attr snap enabled true", "tool.pipe.attr snap types vertex"])
            penCommand(s);
        scope (exit) postJson("/api/command", "tool.pipe.attr snap enabled false");
        clickPixels(px);
        penCommand("tool.set prim.vertex off");
        auto vs = readVerts();
        if (vs.length != num(c["expect_nv"]))
            note(format("%s: %d vertices, expected %s (the foreground vertex and the snapped "
                ~ "one; no weld)", n, vs.length, num(c["expect_nv"])));
        else
            note(within(n, "snapped point", d3(vs[1]), arr3(c["expect_world"]), kRay));
        ++ran;
    }

    // ---- the BASE DRAG (task 9473): Pq carried by the pixel travel, onto the background.
    foreach (n; ["box-drag-surface", "box-drag-handle-off", "box-drag-miss", "box-drag-surface-offset",
                 "box-drag-surface-top", "box-drag-off-control", "box-drag-persp-down",
                 "sphere-drag-surface", "cylinder-drag-surface", "cone-drag-surface",
                 "capsule-drag-surface", "torus-drag-surface", "sphere-drag-surface-offset"]) {
        if (!wanted(n)) continue;
        note(baseDragCell(n, cell(n), rigOf(n)));
        ++ran;
    }

    const want = only is null ? 24 : cast(int)only.length;
    assert(ran == want, format("cell population: %d run, expected %d", ran, want));
    assert(fails.length == 0, "create click surface cells:\n" ~ fails.join("\n"));
}
