// Polygon pen click plane, against the captured cells of
// tests/fixtures/pen_placement.json (A0, E, B0, B1, B2): point 0 lands on the
// plane through the camera focus; a later click lands on the plane parallel to
// it through the CURRENT point and is inserted right after it; a dragged point
// moves on the plane through its own position. Positions are world (the
// automatic work plane is the identity frame), so a typed posY 0.5 IS y 0.5.
//
// The focus sits at y = 1 so every rival height (focus plane 1.0, typed value
// read relative to the focus 1.5, first / next / previous point) differs from
// the captured one by >= 0.2. All cells run and report together; the
// must-stay-green cell (A0) is checked first. Cells of OUR behaviour
// follow: the idle and drawing hovers and the edge-on hover. The second
// unittest block holds the first-click plane rule (fixture key `plane_rule`).

import drag_helpers : Vec3, fetchCamera, fetchSnapLast, viewportFromCameraMatrices;
import http_client : getJson;
import pen_rig_helpers;
import std.array : join;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : PI, abs, ceil, cos, floor, round, sin;

void main() {}

private enum double kTolY = 1e-3;   // heights are typed or anchored exactly
private enum double kTolXZ = 0.02;  // clicked x/z round to whole pixels

// A non-number (a NaN published as null) reads as NaN; every tolerance test
// below is written `!(|d| <= tol)` so a NaN fails it.
private double num(JSONValue v) {
    return v.type == JSONType.integer ? cast(double)v.integer
         : v.type == JSONType.uinteger ? cast(double)v.uinteger
         : v.type == JSONType.float_ ? v.floating : double.nan;
}
private bool near(double a, double b, double tol) { return abs(a - b) <= tol; }
private Vec3 xz(JSONValue a) {
    return Vec3(cast(float)num(a.array[0]), 0, cast(float)num(a.array[1]));
}

/// Compare the committed vertices with the cell's expected list (one line per
/// failing cell and coordinate kind); `skipXZ` names the point whose x/z is
/// not scored (the dragged point).
private string[] compare(string cell, Vec3[] got, JSONValue expected,
                         int skipXZ = -1) {
    auto want = expected.array;
    if (got.length != want.length)
        return [format("%s: %d vertices committed, expected %d", cell,
                       got.length, want.length)];
    double[] gotY, wantY;
    bool badY, badXZ;
    foreach (i, w; want) {
        auto e = w.array;
        gotY ~= got[i].y; wantY ~= num(e[1]);
        badY |= !near(got[i].y, num(e[1]), kTolY);
        badXZ |= cast(int)i != skipXZ && !(near(got[i].x, num(e[0]), kTolXZ) &&
                                           near(got[i].z, num(e[2]), kTolXZ));
    }
    string[] fails;
    if (badY)
        fails ~= format("%s: y = %(%.4f %), expected %(%.4f %)", cell, gotY, wantY);
    if (badXZ)
        fails ~= format("%s: x/z off by more than %s (got %s)", cell, kTolXZ, got);
    return fails;
}

private string[] currentAfter(string cell, JSONValue expected) {
    const cur = penAttrValue("currentPoint");
    const want = num(expected["current_after"]);
    return cur == want ? null
        : [format("%s: currentPoint after the gesture = %s, expected %s",
                  cell, cur, want)];
}

private string[] commitAndCompare(string cell, JSONValue expected, int skipXZ = -1) {
    penCommand("tool.set pen off");
    return compare(cell, readVerts(), expected["vertices"], skipXZ);
}

private void typeHeight(int point, double y) {
    penAttr("currentPoint", point);
    penAttr("posY", y);
}

unittest {
    auto fx = parseJSON(import("fixtures/pen_placement.json"));
    auto cells = fx["cells"];
    const focus = Vec3(0, cast(float)num(fx["rig"]["focus_plane_y"]), 0);
    assert(focus.y == 1.0f, "rig premise: the focus plane must sit at y 1");
    string[] fails;

    // A0 (must stay green): three clicks on the focus plane.
    {
        auto c = cells["A0"];
        penRigEmpty(focus);
        Vec3[] pts;
        foreach (p; c["clicks_xz"].array) pts ~= xz(p);
        clickWorld(pts);
        fails ~= commitAndCompare("A0", c["expected"]);
    }
    // E: point 0 typed to y 0.5; the next two clicks land through it.
    {
        auto c = cells["E"];
        auto k = c["clicks_xz"].array;
        penRigEmpty(focus);
        clickWorld(xz(k[0]));
        penAttr("posY", 0.5);
        clickWorld(xz(k[1]), xz(k[2]));
        fails ~= commitAndCompare("E", c["expected"]);
    }
    // B0: heights 0.2 / 0.5 / 0.8, the last-edited point is p1, current 2.
    {
        auto c = cells["B0_append"];
        auto k = c["clicks_xz"];
        penRigEmpty(focus);
        clickWorld(xz(k["p0"]), xz(k["p1"]), xz(k["p2"]));
        typeHeight(2, 0.8); typeHeight(0, 0.2); typeHeight(1, 0.5);
        penAttr("currentPoint", 2);
        clickWorld(xz(k["extra"]));
        fails ~= currentAfter("B0", c["expected"]);
        fails ~= commitAndCompare("B0", c["expected"]);
    }
    // B1: same heights, current 0: the click is inserted at index 1.
    {
        auto c = cells["B1_insert"];
        auto k = c["clicks_xz"];
        penRigEmpty(focus);
        clickWorld(xz(k["p0"]), xz(k["p1"]), xz(k["p2"]));
        typeHeight(1, 0.5); typeHeight(2, 0.8); typeHeight(0, 0.2);
        penAttr("currentPoint", 0);
        clickWorld(xz(k["extra"]));
        fails ~= currentAfter("B1", c["expected"]);
        fails ~= commitAndCompare("B1", c["expected"]);
    }
    // B2: p1 (y 0.5) dragged while the last / current point is p2 (y 0.8).
    {
        auto c = cells["B2_drag"];
        auto k = c["clicks_xz"];
        penRigEmpty(focus);
        clickWorld(xz(k["p0"])); penAttr("posY", 0.2);
        clickWorld(xz(k["p1"])); penAttr("posY", 0.5);
        clickWorld(xz(k["p2"])); penAttr("posY", 0.8);
        dragWorld(xz(k["p1"]), cast(int)num(c["drag_px"]));
        fails ~= currentAfter("B2", c["expected"]);
        penCommand("tool.set pen off");
        auto got = readVerts();
        fails ~= compare("B2", got, c["expected"]["vertices"],
            cast(int)num(c["expected"]["dragged_point_index"]));
        // Ours: the drag did happen (40 px is > 0.1 m at this zoom).
        if (got.length == 3 && !(got[1].x - xz(k["p1"]).x >= 0.1))
            fails ~= format("B2: the dragged point did not move (x %.3f)", got[1].x);
    }

    // Hover uses the anchor the next click would use. Idle, in a FRONT view
    // with the focus at z 0.4: the published hover point lies on the plane
    // through the focus (z 0.4, not the origin's 0), not a cleared result.
    {
        penRigEmpty(Vec3(0, 1, 0.4f), "Front");
        penCommand("tool.pipe.attr snap enabled true");
        penCommand("tool.pipe.attr snap types grid");
        hoverWorld(Vec3(0.5, 1.5, 0.4f));
        auto p = fetchSnapLast()["worldPos"].array;
        penCommand("tool.pipe.attr snap enabled false");
        if (!(near(num(p[0]), 0.5, kTolXZ) && near(num(p[1]), 1.5, kTolXZ) &&
              near(num(p[2]), 0.4, kTolY)))
            fails ~= format("idle hover, front view: hover point (%s, %s, %s), "
                ~ "expected (0.5, 1.5, 0.4)", num(p[0]), num(p[1]), num(p[2]));
    }
    // Drawing: point 0 typed to y 0.5, the hover point lies on the plane
    // through the current point (y 0.5; the focus plane is 1, the origin 0).
    {
        auto k = cells["A0"]["clicks_xz"].array;
        penRigEmpty(focus);
        penCommand("tool.pipe.attr snap enabled true");
        penCommand("tool.pipe.attr snap types grid");
        clickWorld(xz(k[0]));
        penAttr("posY", 0.5);
        hoverWorld(xz(k[1]));
        auto p = fetchSnapLast()["worldPos"].array;
        penCommand("tool.set pen off");
        penCommand("tool.pipe.attr snap enabled false");
        if (!near(num(p[1]), 0.5, kTolY))
            fails ~= format("drawing hover: hover point (%s, %s, %s), expected "
                ~ "y 0.5 (the current point's plane)", num(p[0]), num(p[1]),
                num(p[2]));
    }

    // Once the plane is locked, a view that sees it edge-on gives no hover
    // point: the preview is cleared, not left at the last click's point.
    {
        penRigEmpty(focus);
        // Snap on, so the click publishes a non-empty result a stale preview
        // would keep (with snap off every result is the cleared one).
        penCommand("tool.pipe.attr snap enabled true");
        penCommand("tool.pipe.attr snap types grid");
        clickWorld(xz(cells["A0"]["clicks_xz"].array[0]));
        const clicked = fetchSnapLast()["worldPos"].array;
        penCommand("viewport.view Front");
        const live = penAttrValue("currentPoint");
        hoverWorld(Vec3(0.5, 1.5, 0));
        auto snap = fetchSnapLast();
        auto p = snap["worldPos"].array;
        penCommand("tool.set pen off");
        penCommand("tool.pipe.attr snap enabled false");
        if (!near(num(clicked[1]), 1.0, kTolY))
            fails ~= format("edge-on rig: the click published %s, expected a "
                ~ "point at y 1 (a cleared result cannot show staleness)", clicked);
        else if (live != 0)
            fails ~= format("edge-on rig: the stroke did not survive the view "
                ~ "change (currentPoint %s)", live);
        else if (snap["snapped"].type != JSONType.false_ ||
                 !(near(num(p[0]), 0, kTolY) && near(num(p[1]), 0, kTolY) &&
                   near(num(p[2]), 0, kTolY)))
            fails ~= format("edge-on hover: snap %s, expected a cleared result",
                            snap.toString);
    }

    assert(fails.length == 0, "pen placement cells:\n" ~ fails.join("\n"));
}

// ===========================================================================
// First-click plane rule (fixture key `plane_rule`). The first click's plane
// is perpendicular to the most-facing plane-local axis k and passes through
// the view focus's plane-local coordinate on k: exact in ortho; in perspective
// every focus channel is rounded to the view's sub-step q and channel k then
// to 10 x the grid size, half away from zero. The click's anchor is rounded to
// q, so a click's plane-normal channel is quantised; a typed value and a
// dragged point's are not.
//
// Every rig sets OUR view scale to the cell's px/m and first asserts that our
// grid size and sub-step equal the cell's (a scale drift fails loudly instead
// of moving a row to another rung). The plane channel is compared to 1e-5 (a
// multiple of q or of 10 x grid); in-plane channels to 1e-4 in ortho and by
// lattice membership under our q in perspective (a perspective pixel is not
// reachable exactly). All cells report together; floors sit beside loops.
// ===========================================================================

private enum double kTolPlane = 1e-5;
private enum double kTolQ = 1e-4;

private double rnd(double x) { return x >= 0 ? floor(x + 0.5) : ceil(x - 0.5); }

private double[3] arr3(JSONValue a) {
    return [num(a.array[0]), num(a.array[1]), num(a.array[2])];
}
private Vec3 v3(double[3] a) {
    return Vec3(cast(float)a[0], cast(float)a[1], cast(float)a[2]);
}

/// A pinned work plane: centre and rotation (degrees), basis Rz*Rx*Ry as the
/// work-plane stage builds it; axis 1 is the plane normal.
private struct Pin {
    double[3] c;
    double rx = 0, ry = 0, rz = 0;

    double[3] axis(int i) const {
        double[3] v = [i == 0, i == 1, i == 2];
        const a = rx * PI / 180, b = ry * PI / 180, g = rz * PI / 180;
        const x = cos(b) * v[0] + sin(b) * v[2], y = v[1], z = -sin(b) * v[0] + cos(b) * v[2];
        const y2 = cos(a) * y - sin(a) * z, z2 = sin(a) * y + cos(a) * z;
        return [cos(g) * x - sin(g) * y2, sin(g) * x + cos(g) * y2, z2];
    }
    double[3] toWorld(double[3] l) const {
        double[3] w = c;
        foreach (i; 0 .. 3) foreach (j; 0 .. 3) w[j] += axis(i)[j] * l[i];
        return w;
    }
    double[3] toLocal(double[3] w) const {
        double[3] l;
        foreach (i; 0 .. 3) {
            const e = axis(i);
            l[i] = (w[0] - c[0]) * e[0] + (w[1] - c[1]) * e[1] + (w[2] - c[2]) * e[2];
        }
        return l;
    }
    string command() const {
        return format("workplane.edit cenX:%s cenY:%s cenZ:%s rotX:%s rotY:%s rotZ:%s",
                      c[0], c[1], c[2], rx, ry, rz);
    }
}
private enum Pin kNoPin = Pin([0, 0, 0]);

/// Rig premise: OUR grid size and sub-step equal the cell's.
private void assertGrid(string cell, double grid, double q) {
    auto g = getJson("/api/viewport/display")["cells"].array[0]["grid"];
    const size = num(g["size"]), sub = num(g["subStep"]);
    assert(abs(size - grid) <= 1e-6 * grid && abs(sub - q) <= 1e-6 * q,
        format("%s rig: our grid size %.9g / sub-step %.9g, the cell's %s / %s "
            ~ "(pixel size %.9g)", cell, size, sub, grid, q, num(g["pixelSize"])));
}

/// Rig premise: the most-facing axis of `pin`'s frame under the live view.
private int facingAxis(Pin pin) {
    const vp = viewportFromCameraMatrices();
    const double[3] back = [vp.view[2], vp.view[6], vp.view[10]];
    int best;
    double bestD = -1;
    foreach (i; 0 .. 3) {
        const e = pin.axis(i);
        const d = abs(back[0] * e[0] + back[1] * e[1] + back[2] * e[2]);
        if (d > bestD) { bestD = d; best = i; }
    }
    return best;
}

/// The current point's channels (the stroke is plane-local).
private double[3] livePoint() {
    return [penAttrValue("posX"), penAttrValue("posY"), penAttrValue("posZ")];
}

private bool onLattice(double v, double q) { return abs(v / q - round(v / q)) < 1e-3; }

private double[3][] worldPts(JSONValue c) {
    double[3][] w;
    foreach (v; c["expected"]["vertices"].array) w ~= arr3(v);
    return w;
}

private long[] ring() {
    auto f = getJson("/api/model")["faces"].array;
    long[] r;
    if (f.length == 1) foreach (e; f[0].array) r ~= e.integer;
    return r;
}

/// One stroke cell: three clicks on world points; after each
/// click the current point's plane channel `k` must equal `plane` and its
/// in-plane channels the fixture's local ones (ortho, 1e-4) or our lattice
/// (perspective). `scoreInPlane[i]` false skips point i's in-plane channels.
/// The stroke stays live.
private string[] strokeCell(string cell, double[3][] world, Pin pin, int k, double plane,
                            bool ortho, double q, bool[3] scoreInPlane = [true, true, true]) {
    string[] fails;
    assert(world.length == 3, cell ~ ": three points");
    double[] gotK;
    bool badK;
    foreach (i, w; world) {
        const want = pin.toLocal(w);
        clickWorld(v3(w));
        const got = livePoint();
        gotK ~= got[k];
        badK |= !(abs(got[k] - plane) <= kTolPlane);
        if (!scoreInPlane[i]) continue;
        foreach (j; 0 .. 3) {
            if (j == k) continue;
            const ok = ortho ? abs(got[j] - want[j]) <= kTolQ : onLattice(got[j], q);
            if (!ok)
                fails ~= format("%s p%d: local channel %d = %.6f, expected %s %.6f",
                    cell, i, j, got[j], ortho ? "" : "on our q lattice, captured",
                    want[j]);
        }
    }
    if (badK)
        fails ~= format("%s: local channel %d of p0..p2 = %(%.6f %), expected %s",
                        cell, k, gotK, plane);
    return fails;
}

unittest {
    auto fx = parseJSON(import("fixtures/pen_placement.json"))["plane_rule"];
    auto b2 = fx["cells_k_b2"], b3 = fx["cells_k_b3"], b4 = fx["cells_k_b4"];
    string[] fails;
    const pinA = Pin([0.5, 0.2, -0.3], 60, 0, 0);
    const pinB = Pin([0.5, 0.2, -0.3], 30, 0, 40);
    const pinC = Pin([0.5, 0.2, -0.3], 20, 0, 0);

    // ---- must stay green -------------------------------------------------
    // B3x-c (perspective, pinned, focus local y 0.3 -> plane 0).
    {
        auto c = b3["B3xc_persp_axisY_focus_0p3"];
        penSceneEmpty("Perspective");
        penCommand(pinC.command());
        penCameraAt(v3(pinC.toWorld(arr3(c["focus_local"]))), 440);
        assertGrid("B3xc", 0.1, 0.005);
        assert(facingAxis(pinC) == 1, "B3xc rig: the most-facing local axis must be y");
        penCommand("tool.set pen on");
        fails ~= strokeCell("B3xc", worldPts(c), pinC, 1, num(c["plane_local_y"]), false, 0.005);
        penCommand("tool.set pen off");
    }
    // B3p (perspective, focus written BEFORE pinning; local z -0.493 -> 0):
    // p2 was an edge press in the capture, so only its plane channel scores.
    {
        auto c = b2["B3p_pinned_perspective"];
        penSceneEmpty("Perspective");
        penCameraAt(Vec3(0.4f, 1, 0.1f), 440);
        penCommand(pinA.command());
        assertGrid("B3p", 0.1, 0.005);
        assert(facingAxis(pinA) == 2, "B3p rig: the most-facing local axis must be z");
        penCommand("tool.set pen on");
        fails ~= strokeCell("B3p", worldPts(c), pinA, 2, 0.0, false, 0.005, [true, true, false]);
        penCommand("tool.set pen off");
    }
    // Q-drag: a dragged point keeps its TYPED plane-normal channel (0.1234;
    // its anchor is the raw point, not a quantised one).
    {
        auto c = b4["Qdrag_typed_normal"];
        penSceneEmpty("Top");
        penCameraAt(Vec3(0.07f, 1, 0), 440);
        assertGrid("Qdrag", 0.1, 0.005);
        penCommand("tool.set pen on");
        clickWorld(Vec3(-0.4f, 1, 0), Vec3(0.4f, 1, 0), Vec3(0, 1, 0.5f));
        penAttr("currentPoint", 0);
        penAttr("posY", 0.1234);
        dragWorld(Vec3(-0.4f, 0.1234f, 0), 40);
        penCommand("tool.set pen off");
        auto got = readVerts();
        auto want = c["expected"]["vertices"].array;
        if (got.length != 3 || !(abs(got[0].y - 0.1234) <= 1e-6) ||
            !(abs(got[0].x - num(want[0].array[0])) <= kTolQ) || ring() != [0, 2, 1])
            fails ~= format("Qdrag: %s ring %s, expected p0 (%.4f, 0.1234, 0) ring [0, 2, 1]",
                            got, ring(), num(want[0].array[0]));
    }

    // ---- must turn (red on the origin / exact-focus anchor) ---------------
    // B3x-a: perspective, focus written while pinned as local (0.4, 0.3, 0.5);
    // local z 0.5 rounds to 1 (step 1).
    {
        auto c = b3["B3xa_persp_focus_written_pinned"];
        penSceneEmpty("Perspective");
        penCommand(pinA.command());
        penCameraAt(v3(pinA.toWorld(arr3(c["focus_local"]))), 440);
        assertGrid("B3xa", 0.1, 0.005);
        assert(facingAxis(pinA) == 2, "B3xa rig: the most-facing local axis must be z");
        penCommand("tool.set pen on");
        fails ~= strokeCell("B3xa", worldPts(c), pinA, 2, num(c["plane_local_z"]), false, 0.005);
        penCommand("tool.set pen off");
    }
    // B3x-b: top ortho, focus world (2, 1, 0) written BEFORE pinning; the view
    // turns with the plane and reads the focus back as local (2, 1, 0).
    {
        auto c = b3["B3xb_ortho_focus_before_pin"];
        penSceneEmpty("Top");
        penCameraAt(Vec3(2, 1, 0), 440);
        penCommand(pinB.command());
        assertGrid("B3xb", 0.1, 0.005);
        const f = fetchCamera().focus;
        const fl = pinB.toLocal([f.x, f.y, f.z]);
        const rb = arr3(c["focus_local_read_back"]);
        assert(abs(fl[0] - rb[0]) <= kTolQ && abs(fl[1] - rb[1]) <= kTolQ &&
               abs(fl[2] - rb[2]) <= kTolQ, format("B3xb rig: the focus reads back "
               ~ "as local %s, the capture's %s", fl, rb));
        penCommand("tool.set pen on");
        fails ~= strokeCell("B3xb", worldPts(c), pinB, 1, num(c["plane_local_y"]), true, 0.005);
        penCommand("tool.set pen off");
    }
    // B3r: the same plane, focus written WHILE pinned as local (2, 1, 0); then
    // a typed position on point 0 stands as typed.
    {
        auto c = b2["B3_pinned_ortho"];
        penSceneEmpty("Top");
        penCommand(pinB.command());
        penCameraAt(v3(pinB.toWorld([2, 1, 0])), 440);
        assertGrid("B3r", 0.1, 0.005);
        penCommand("tool.set pen on");
        auto w = worldPts(c);
        w[0] = pinB.toWorld(arr3(c["first_click_local"]));
        fails ~= strokeCell("B3r", w, pinB, 1, 1.0, true, 0.005);
        const typed = arr3(c["expected"]["current_point_position"]);
        penAttr("currentPoint", 0);
        penAttr("posX", typed[0]); penAttr("posY", typed[1]); penAttr("posZ", typed[2]);
        const got = livePoint();
        penCommand("tool.set pen off");
        if (!(abs(got[0] - typed[0]) <= 1e-6 && abs(got[1] - typed[1]) <= 1e-6 &&
              abs(got[2] - typed[2]) <= 1e-6))
            fails ~= format("B3r: typed position %s reads %s", typed, got);
    }
    // B3x-c2: B3x-c with the focus local y 0.7 (rounds to 1).
    {
        auto c = b3["B3xc2_persp_axisY_focus_0p7"];
        penSceneEmpty("Perspective");
        penCommand(pinC.command());
        penCameraAt(v3(pinC.toWorld(arr3(c["focus_local"]))), 440);
        assertGrid("B3xc2", 0.1, 0.005);
        assert(facingAxis(pinC) == 1, "B3xc2 rig: the most-facing local axis must be y");
        penCommand("tool.set pen on");
        fails ~= strokeCell("B3xc2", worldPts(c), pinC, 1, num(c["plane_local_y"]), false, 0.005);
        penCommand("tool.set pen off");
    }
    // B3x-d: unpinned perspective at 880 px/m (grid 0.05, step 0.5), focus y
    // 0.3 -> plane 0.5.
    {
        auto c = b3["B3xd_persp_unpinned_880"];
        penSceneEmpty("Perspective");
        penCameraAt(Vec3(0.07f, cast(float)num(c["focus_y"]), 0), 880);
        assertGrid("B3xd", num(c["grid"]), 0.002);
        penCommand("tool.set pen on");
        fails ~= strokeCell("B3xd", worldPts(c), kNoPin, 1, num(c["plane_y"]), false, 0.002);
        penCommand("tool.set pen off");
    }
    // Q-depth: top ortho, focus y 1.3333. The click stores 1.335 (the plane
    // channel quantised), a typed 0.1234 stands, the next clicks (anchored on
    // that point) store 0.125.
    {
        auto c = b3["Qdepth_normal_channel"];
        auto w = worldPts(c);
        penSceneEmpty("Top");
        penCameraAt(Vec3(0.07f, 1.3333f, 0), 440);
        assertGrid("Qdepth", 0.1, 0.005);
        penCommand("tool.set pen on");
        clickWorld(v3(w[0]));
        const p0 = livePoint()[1];
        penAttr("posY", 0.1234);
        const typed = livePoint()[1];
        clickWorld(v3(w[1]));
        const p1 = livePoint()[1];
        clickWorld(v3(w[2]));
        const p2 = livePoint()[1];
        penCommand("tool.set pen off");
        auto got = readVerts();
        const want = num(c["p0_after_click_y"]);
        if (!(abs(p0 - want) <= kTolPlane && abs(typed - 0.1234) <= 1e-6 &&
              abs(p1 - 0.125) <= kTolPlane && abs(p2 - 0.125) <= kTolPlane))
            fails ~= format("Qdepth: p0 after the click y %.6f (expected %s), typed "
                ~ "%.6f (0.1234), p1 %.6f, p2 %.6f (0.125)", p0, want, typed, p1, p2);
        bool badXZ = got.length != 3;
        foreach (i; 0 .. (got.length == 3 ? 3 : 0))
            badXZ |= !(abs(got[i].x - w[i][0]) <= kTolQ && abs(got[i].z - w[i][2]) <= kTolQ);
        if (badXZ || ring() != [0, 2, 1])
            fails ~= format("Qdepth: committed %s ring %s, expected x/z of %s ring [0, 2, 1]",
                            got, ring(), w);
    }
    // Ortho sweep (top, 440 px/m): the plane is the focus exactly; the click
    // stores it rounded to q.
    {
        int n;
        string[] bad;
        foreach (r; b3["plane_offset_sweep"]["rows"].array) {
            if (r["projection"].str != "ortho") continue;
            const f = arr3(r["focus"]), q = num(r["q"]);
            penSceneEmpty("Top");
            penCameraAt(v3(f), num(r["px_per_m"]));
            assertGrid(format("ortho row %s", f[1]), num(r["grid"]), q);
            penCommand("tool.set pen on");
            auto cam = fetchCamera();
            clickPixels([cam.vpX + cam.width / 2, cam.vpY + cam.height / 2]);
            const got = livePoint()[1];
            penCommand("tool.set pen off");
            const want = rnd(num(r["plane"]) / q) * q;
            ++n;
            if (!(abs(got - want) <= kTolPlane))
                bad ~= format("focus %s -> %.6f (expected %s)", f[1], got, want);
        }
        assert(n == 8, format("ortho sweep population: %d rows, expected 8", n));
        if (bad.length) fails ~= format("ortho sweep: %-(%s; %)", bad);
    }
    // Perspective rows (sweeps and the tie bisection): one click at the view
    // centre, the first point's channel on the row's axis is the plane. The
    // 18 `zone` rows lie just below a tie: rounding the focus to q first
    // moves them onto it.
    {
        int n, zone;
        string[] bad;
        foreach (rows; [b3["plane_offset_sweep"]["rows"], b4["PR_rounding"]["rows"]])
        foreach (r; rows.array) {
            if (r["projection"].str != "perspective") continue;
            const f = arr3(r["focus"]);
            const k = cast(int)num(r["axis"]);
            penSceneEmpty("Perspective");
            penCameraAt(v3(f), num(r["px_per_m"]), 0, k == 1 ? 1.5 : 0.15);
            const id = format("row %s axis %d at %s px/m", f[k], k, num(r["px_per_m"]));
            assertGrid(id, num(r["grid"]), num(r["q"]));
            assert(facingAxis(kNoPin) == k, id ~ " rig: wrong most-facing axis");
            penCommand("tool.set pen on");
            auto cam = fetchCamera();
            clickPixels([cam.vpX + cam.width / 2, cam.vpY + cam.height / 2]);
            const got = livePoint()[k];
            penCommand("tool.set pen off");
            ++n;
            const z = r["zone"].type == JSONType.true_;
            zone += z;
            if (!(abs(got - num(r["plane"])) <= kTolPlane))
                bad ~= format("%s%s -> %.6f (expected %s)", id, z ? " [zone]" : "",
                              got, num(r["plane"]));
        }
        assert(n == 74 && zone == 18, format("perspective rows: %d run (%d zone), "
            ~ "expected 74 (18)", n, zone));
        if (bad.length)
            fails ~= format("perspective rows, %d of 74 wrong: %-(%s; %)", bad.length, bad);
    }

    assert(fails.length == 0, "first-click plane rule:\n" ~ fails.join("\n"));
}
