// Where a click lands on the view work plane, for every click reader, against
// tests/fixtures/create_click_plane.json (captures K-W / K-W2, task 9411): the
// plane perpendicular to the most-facing frame axis through the view anchor
// (perspective: the focus rounded to ten grid steps after a q pre-snap; ortho:
// the focus), the hit snapped to q on EVERY channel, plane-local under a pin.
// The action-centre relocate reads the same law under a pinned perspective
// plane; an ortho view keeps the pre-press centre's depth.
//
// Every cell sets OUR view scale to the cell's px/m and first asserts that our
// grid size and sub-step equal the cell's (a quantum cell must sit in the
// measured q's ladder bracket). The click is the pixel of the captured point;
// the rig asserts that the raw hit of that pixel on the captured plane lies
// within q/2 of the captured point on every channel, so a q-snapped answer is
// exact and every channel is compared to 1e-4. The plane channel is the
// discriminator (W1a y 0 vs RAW 0.37, W1c 5 vs 5.33, W1c_40 10 vs R13 5.35,
// W1g local z 1.0 vs unrounded 0.7, W2a local y 1.0 vs RAW-PLANE); W1d is the
// in-plane quantum (0.305 vs raw 0.30636). W1k / W1k_pin (a wrapped command's
// click handle) have no read channel: the handle reads the same function as
// the falloff point (tests/unit/view_work_plane_anchor_census_test.d).

import drag_helpers : Vec3, Viewport, buildDragLog, fetchCamera, pixelRay,
    playAndWait, viewportFromCameraMatrices;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import pen_rig_helpers : clickPixels, penCameraAt, penCommand, penSceneEmpty,
    worldPixel;
import std.array : join;
import std.conv : to;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : PI, abs, asin, atan2, cos, sin;
import std.string : split;

void main() {}

private enum double kTol = 1e-4;

private double num(JSONValue v) {
    return v.type == JSONType.integer ? cast(double)v.integer
         : v.type == JSONType.uinteger ? cast(double)v.uinteger
         : v.type == JSONType.float_ ? v.floating : double.nan;
}
private double[3] arr3(JSONValue a) {
    return [num(a.array[0]), num(a.array[1]), num(a.array[2])];
}
private Vec3 v3(double[3] a) {
    return Vec3(cast(float)a[0], cast(float)a[1], cast(float)a[2]);
}

/// The cell's construction plane: world = origin + Rx(rotX) * frame.
private struct Pin {
    double[3] c;
    double rx = 0;
    bool pinned() const { return rx != 0 || c != [0.0, 0.0, 0.0]; }
    double[3] toWorld(double[3] l) const {
        const a = rx * PI / 180;
        return [c[0] + l[0], c[1] + cos(a) * l[1] - sin(a) * l[2],
                c[2] + sin(a) * l[1] + cos(a) * l[2]];
    }
    double[3] dirToWorld(double[3] l) const {   // rotation only
        const w = toWorld(l);
        return [w[0] - c[0], w[1] - c[1], w[2] - c[2]];
    }
}

private struct Cell {
    string name;
    JSONValue j;
    Pin pin;
    bool persp;
    double ppm, q, grid;
    double[3] focusWorld, measuredFrame, measuredWorld;
    int axis;   // most-facing frame axis
}

private Cell cellOf(JSONValue fx, string name) {
    Cell c;
    c.name = name;
    c.j = fx["cells"][name];
    auto v = c.j["view"], p = c.j["plane"];
    c.pin = Pin(arr3(p["origin"]), num(p["rot_x_deg"]));
    c.persp = v["projection"].str == "perspective";
    c.ppm = num(v["px_per_m"]); c.q = num(v["q"]); c.grid = num(v["grid"]);
    c.focusWorld = c.pin.toWorld(arr3(v["focus_frame"]));
    c.measuredFrame = arr3(c.j["measured_frame"]);
    c.measuredWorld = arr3(c.j["measured_world"]);
    c.axis = v["most_facing_axis"].str == "X" ? 0 : (v["most_facing_axis"].str == "Y" ? 1 : 2);
    return c;
}

/// Scene (empty, or `geometry` commands), the pin, the camera at the cell's
/// focus / scale / view direction, with the rig premises asserted.
private void rig(const ref Cell c, string[] geometry = null) {
    penSceneEmpty(c.persp ? "Perspective" : "Top");
    foreach (g; geometry) penCommand(g);
    if (c.pin.pinned)
        penCommand(format("workplane.edit cenX:%.9f cenY:%.9f cenZ:%.9f rotX:%.9f",
                          c.pin.c[0], c.pin.c[1], c.pin.c[2], c.pin.rx));
    if (c.persp) {
        const b = c.pin.dirToWorld(arr3(c.j["view"]["camera_back_frame"]));
        // A straight-down camera sits at the elevation clamp; its plane axis
        // is still Y (asserted below), which is all the law reads.
        const el = abs(b[1]) > 0.999 ? 1.5 : asin(b[1]);
        penCameraAt(v3(c.focusWorld), c.ppm, atan2(b[0], b[2]), el);
    } else {
        penCameraAt(v3(c.focusWorld), c.ppm);
    }
    auto g = getJson("/api/viewport/display")["cells"].array[0]["grid"];
    assert(abs(num(g["size"]) - c.grid) <= 1e-6 * c.grid
        && abs(num(g["subStep"]) - c.q) <= 1e-6 * c.q,
        format("%s rig: our grid %.9g / q %.9g, the cell's %s / %s", c.name,
               num(g["size"]), num(g["subStep"]), c.grid, c.q));
    const vp = viewportFromCameraMatrices();
    const double[3] back = [vp.view[2], vp.view[6], vp.view[10]];
    int best; double bestD = -1;
    foreach (i; 0 .. 3) {
        double[3] e = 0; e[i] = 1;
        const w = c.pin.dirToWorld(e);
        const d = abs(back[0] * w[0] + back[1] * w[1] + back[2] * w[2]);
        if (d > bestD) { bestD = d; best = i; }
    }
    assert(best == c.axis, format("%s rig: most-facing frame axis %d, the cell's %d",
                                  c.name, best, c.axis));
}

/// The window pixel of the captured point; asserts its ray meets the captured
/// plane within q/2 of the captured point (so a q-snapped answer is exact).
private int[2] aim(const ref Cell c) {
    const px = worldPixel(v3(c.measuredWorld));
    auto vp = viewportFromCameraMatrices();
    Vec3 o, d;
    pixelRay(px[0], px[1], vp, o, d);
    double[3] n = 0; n[c.axis] = 1;
    const nw = c.pin.dirToWorld(n);
    const double[3] po = c.measuredWorld, oo = [o.x, o.y, o.z], dd = [d.x, d.y, d.z];
    double num_ = 0, den = 0;
    foreach (i; 0 .. 3) { num_ += (po[i] - oo[i]) * nw[i]; den += dd[i] * nw[i]; }
    const t = num_ / den;
    foreach (i; 0 .. 3)
        assert(abs(oo[i] + dd[i] * t - po[i]) < 0.45 * c.q,
            format("%s rig: pixel %s lands %.5f off the captured point on world "
                   ~ "channel %d (q %s)", c.name, px, oo[i] + dd[i] * t - po[i], i, c.q));
    return px;
}

private string compare(const ref Cell c, double[3] got, bool local) {
    const want = local ? c.measuredFrame : c.measuredWorld;
    foreach (i; 0 .. 3)
        if (!(abs(got[i] - want[i]) <= kTol))
            return format("%s (%s): %s %(%.5f %), captured %(%.5f %) (%s; next "
                ~ "family %s %.3f m off)", c.name, c.j["gesture"].str,
                local ? "local" : "world", got[], want[], c.j["winner"].str,
                c.j["next_family"].str, num(c.j["margin_to_next_family"]));
    return null;
}

private double[3][] modelVerts() {
    double[3][] r;
    foreach (v; getJson("/api/model")["vertices"].array) r ~= arr3(v);
    return r;
}

private double[3] nearest(double[3][] vs, double[3] p) {
    double[3] best = double.nan;
    double bd = double.infinity;
    foreach (v; vs) {
        double d = 0;
        foreach (i; 0 .. 3) d += (v[i] - p[i]) ^^ 2;
        if (d < bd) { bd = d; best = v; }
    }
    return best;
}

private double[3] attrVec(string tool, string[3] names) {
    double[3] r;
    foreach (i, n; names) {
        auto a = postJson("/api/command", "tool.attr " ~ tool ~ " " ~ n ~ " ?");
        assert(a["status"].str == "ok", tool ~ " " ~ n ~ ": " ~ a.toString);
        r[i] = num(a["value"]);
    }
    return r;
}

private string[string] stageAttrs(string task) {
    foreach (st; getJson("/api/toolpipe")["stages"].array)
        if (st["task"].str == task) {
            string[string] r;
            foreach (k, v; st["attrs"].object) r[k] = v.str;
            return r;
        }
    assert(false, task ~ " stage missing from /api/toolpipe");
}

private void drag(int[2] p, int dx, ubyte btn = 1, int steps = 4) {
    auto cam = fetchCamera();
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             p[0], p[1], p[0] + dx, p[1] - dx, steps, 0, btn));
}

// ---- the readers ---------------------------------------------------------

/// Box (press = the base corner) — the created vertex nearest the point.
private string boxCell(const ref Cell c) {
    rig(c);
    penCommand("tool.set prim.cube");
    drag(aim(c), 60);
    penCommand("tool.set prim.cube off");
    return compare(c, nearest(modelVerts(), c.measuredWorld), false);
}

/// Vertex tool: one click, the created vertex.
private string vertexCell(const ref Cell c) {
    rig(c);
    penCommand("tool.set prim.vertex");
    clickPixels(aim(c));
    penCommand("tool.set prim.vertex off");
    auto vs = modelVerts();
    if (vs.length != 1) return format("%s: %d vertices created, expected 1", c.name, vs.length);
    return compare(c, vs[0], false);
}

/// Sphere / torus (press = the centre): the centre channels, plane-local.
private string radialCell(const ref Cell c, string tool) {
    rig(c);
    penCommand("tool.set " ~ tool);
    drag(aim(c), 40);
    auto got = attrVec(tool, ["cenX", "cenY", "cenZ"]);
    penCommand("tool.set " ~ tool ~ " off");
    return compare(c, got, true);
}

// A source polygon far off-screen, selected: the radial array and the
// falloff need geometry, none of it near the click.
private enum string[] kSource = [
    "prim.cube cenX:-6 cenY:0 cenZ:6 sizeX:0.2 sizeY:0.2 sizeZ:0.2",
    "select.typeFrom polygon", "select.polygon"];

/// Radial array: an off-handle click moves the rotation centre (world).
private string radialArrayCell(const ref Cell c) {
    rig(c, kSource);
    penCommand("tool.set mesh.radialArrayTool");
    clickPixels(aim(c));
    auto r = postJson("/api/command", "tool.attr mesh.radialArrayTool center ?");
    penCommand("tool.set mesh.radialArrayTool off");
    return compare(c, arr3(r["value"]), false);
}

/// Point falloff: a right-button press with no motion places the centre.
private string falloffCell(const ref Cell c) {
    rig(c, kSource);
    penCommand("tool.set move");
    penCommand("tool.pipe.attr falloff type radial");
    const p = aim(c);
    auto cam = fetchCamera();
    playAndWait(format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,`
        ~ `"vpH":%d,"fovY":0.785398}` ~ "\n" ~ `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN",`
        ~ `"btn":3,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n" ~ `{"t":100.000,`
        ~ `"type":"SDL_MOUSEBUTTONUP","btn":3,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        cam.vpX, cam.vpY, cam.width, cam.height, p[0], p[1], p[0], p[1]));
    auto parts = stageAttrs("WGHT")["center"].split(",");
    penCommand("tool.pipe.attr falloff type none");
    penCommand("tool.set move off");
    return compare(c, [parts[0].to!double, parts[1].to!double, parts[2].to!double], false);
}

/// The action-centre relocate: Move armed, a click in empty space; `prior`
/// (world centre, half size 0.15) is a selected cube giving the pre-press
/// centre.
private string relocateCell(const ref Cell c, double[] prior) {
    rig(c, [format("prim.cube cenX:%.9f cenY:%.9f cenZ:%.9f sizeX:0.3 sizeY:0.3 sizeZ:0.3",
                      prior[0], prior[1], prior[2])]);
    const n = getJson("/api/model")["vertices"].array.length;
    string idx;
    foreach (i; 0 .. n) idx ~= (i ? "," : "") ~ i.to!string;
    auto r = postJson("/api/command", commandBody("mesh.select",
        `{"mode":"vertices","indices":[` ~ idx ~ `]}`));
    assert(r["status"].str == "ok", c.name ~ " rig: select failed " ~ r.toString);
    penCommand("tool.set move");
    penCommand("tool.pipe.attr actionCenter mode auto");
    auto pa = stageAttrs("ACEN");
    const double[3] pre = [pa["cenX"].to!double, pa["cenY"].to!double, pa["cenZ"].to!double];
    assert(abs(pre[0] - prior[0]) + abs(pre[1] - prior[1]) + abs(pre[2] - prior[2]) < 1e-4,
        format("%s rig: the pre-press centre %s, expected the cube's %s", c.name, pre, prior));
    clickPixels(aim(c));
    auto a = stageAttrs("ACEN");
    penCommand("tool.set move off");
    if (a["userPlaced"] != "true")
        return format("%s: the click did not relocate (userPlaced %s)", c.name, a["userPlaced"]);
    return compare(c, [a["cenX"].to!double, a["cenY"].to!double, a["cenZ"].to!double], false);
}

unittest {
    auto fx = parseJSON(import("fixtures/create_click_plane.json"));
    string[] fails;
    int ran;
    void run(string name, string function(const ref Cell) f) {
        const c = cellOf(fx, name);
        if (auto m = f(c)) fails ~= m;
        ++ran;
    }

    // In-plane quantum first (W1d): our raw x of the clicked pixel must round
    // to the captured 0.305 and differ from it, or the cell sees nothing.
    {
        const c = cellOf(fx, "W1d");
        rig(c);
        const p = worldPixel(Vec3(0.30636f, 0.37f, 0.21f));
        auto vp = viewportFromCameraMatrices();
        Vec3 o, d;
        pixelRay(p[0], p[1], vp, o, d);
        assert(o.x > 0.3025 && o.x < 0.3075 && abs(o.x - 0.305) > 1e-4,
            format("W1d rig: raw x %.5f must round to 0.305 and differ from it", o.x));
        penCommand("tool.set prim.cube");
        drag(p, 60);
        penCommand("tool.set prim.cube off");
        if (auto m = compare(c, nearest(modelVerts(), c.measuredWorld), false)) fails ~= m;
        ++ran;
    }
    foreach (n; ["W1a", "W1a_q", "W1b", "W1c", "W1c_40", "W1i"]) run(n, &boxCell);
    foreach (n; ["W1e", "W1e_q", "W1g"]) run(n, &vertexCell);
    foreach (n; ["W1f", "W1f_q", "W1h"]) run(n, &radialArrayCell);
    foreach (n; ["W1j", "W1j_obl", "W1j_pin"]) run(n, &falloffCell);
    foreach (n; ["W1l", "W1l_pin"])
        run(n, function(ref const Cell c) => radialCell(c, "prim.sphere"));
    foreach (n; ["W1m", "W1m_pin"])
        run(n, function(ref const Cell c) => radialCell(c, "prim.torus"));
    // Relocate: a pinned perspective view reads the law (W2a); an ortho view
    // keeps the prior depth (W2b, W2c_ctrl). The item-mode rows (W2c_item,
    // W2c_item_ctrl, W2d_item: the reference relocates onto the anchor plane)
    // are not run: our item mode holds the off-gizmo press back and never
    // relocates (test_item_panel_gizmo_sync R3) — an open gap, task 9411.
    run("W2a", function(ref const Cell c) => relocateCell(c, [-0.5, 0.0, 0.0]));
    run("W2c_ctrl", function(ref const Cell c) => relocateCell(c, [-0.5, -0.4, -0.3]));
    {
        // W2b: the prior's world centre is the captured local prior.
        const c = cellOf(fx, "W2b");
        const w = c.pin.toWorld(arr3(c.j["prior_centre_frame"]));
        if (auto m = relocateCell(c, w[].dup)) fails ~= m;
        ++ran;
    }
    assert(ran == 23, format("cell population: %d run, expected 23", ran));
    assert(fails.length == 0, "click plane cells:\n" ~ fails.join("\n"));
}
