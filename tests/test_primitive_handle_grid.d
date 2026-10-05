// A primitive handle's POINT snaps from press + travel (task 9472, captures
// K-H / K-H2, fixture `tests/fixtures/handle_grid_slow.json`): every event
// places the dragged handle at its press position plus the pointer travel and
// snaps THAT point to the grid node; the snapped point is never fed back; the
// mover snaps centre + travel, not the grabbed arrow point; the size follows
// from the snapped point by the family's handle mode (sphere / torus
// / capsule symmetric, cylinder / cone one-sided — K-H2). Rig: top ortho
// (front for the height cells) at 439.52 px/m, grid 0.1, grid bit only, every
// drag 20 events of 2 px; every drag publishes its snap (the overlay). One
// cell repeats under a work plane pinned 1 m along x (a lattice multiple, so
// world and plane nodes agree): the handle point crosses the frame both ways.

import drag_helpers : Vec3, buildDragDownLog, buildDragMotionLog, buildDragUpLog,
    fetchCamera, fetchHandlePart, fetchSnapLast, playAndWait;
import http_client : postJson;
import pen_rig_helpers : penCameraAt, penCommand, penSceneEmpty, worldPixel;
import std.algorithm : canFind;
import std.file : readText;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : abs;
import std.string : indexOf;

void main() {}

private enum double kPpm = 439.52;
private enum double kTol = 1e-4;
private JSONValue fx;
private int ran;
private string[] fails;

private double num(JSONValue v) {
    return v.type == JSONType.integer ? cast(double)v.integer
         : v.type == JSONType.float_ ? v.floating : double.nan;
}

private string tool;   // the armed primitive
private float planeX = 0;  // the pinned work plane's x offset (0 = the default plane)
private double qa(string attr) {
    auto r = postJson("/api/command", "tool.attr " ~ tool ~ " " ~ attr ~ " ?");
    assert(r["status"].str == "ok", "query " ~ attr ~ " failed: " ~ r.toString);
    return num(r["value"]);
}

/// The X / Y extents of the armed primitive along its local X / Y (axis Y).
private double[2] xExtent() {
    const r = tool == "prim.torus" ? qa("majorRadius") + qa("minorRadius") : qa("sizeX");
    return [qa("cenX") - r, qa("cenX") + r];
}
private double[2] yExtent() {
    const h = tool == "prim.torus" ? qa("minorRadius") : qa("sizeY");
    return [qa("cenY") - h, qa("cenY") + h];
}

/// Empty scene, top ortho; `t` armed, its base drawn with snap off, then the
/// cell's shape typed; the front view for a height cell; grid snap on.
private void rig(string t, JSONValue c, bool front) {
    tool = t;
    penSceneEmpty("Top");
    if (planeX != 0)
        penCommand(format("workplane.edit cenX:%s cenY:0 cenZ:0 rotX:0 rotY:0 rotZ:0", planeX));
    penCameraAt(Vec3(planeX, 1, 0), kPpm);
    penCommand("tool.set " ~ t);
    penCommand("tool.pipe.attr snap enabled false");
    const a = worldPixel(Vec3(planeX - 0.1f, 0, -0.1f)), b = worldPixel(Vec3(planeX + 0.1f, 0, 0.1f));
    auto cam = fetchCamera();
    playAndWait(buildDragDownLog(cam.vpX, cam.vpY, cam.width, cam.height, a[0], a[1]));
    playAndWait(buildDragMotionLog(cam.vpX, cam.vpY, cam.width, cam.height, a[0], a[1], b[0], b[1], 8));
    playAndWait(buildDragUpLog(cam.vpX, cam.vpY, cam.width, cam.height, b[0], b[1]));
    auto cen = c["cen"].array;
    string[2][] attrs = [["cenX", format("%s", num(cen[0]))], ["cenY", format("%s", num(cen[1]))],
                         ["cenZ", format("%s", num(cen[2]))]];
    if (t == "prim.torus") {
        attrs ~= [["majorRadius", "0.2"], ["minorRadius", "0.1"]];
    } else {
        const r = "radius" in c ? format("%s", num(c["radius"])) : "0.3";
        const h = "half_length" in c ? format("%s", num(c["half_length"])) : r;
        attrs ~= [["sizeX", r], ["sizeY", h], ["sizeZ", r]];
    }
    foreach (kv; attrs) penCommand("tool.attr " ~ t ~ " " ~ kv[0] ~ " " ~ kv[1]);
    if (front) {
        penCommand("viewport.view Front");
        penCameraAt(Vec3(planeX, cast(float)num(cen[1]), 0), kPpm);
    }
    penCommand("tool.pipe.attr snap enabled true");
    penCommand("tool.pipe.attr snap types grid");
    penCommand("tool.pipe.attr snap fixedGrid false");
    penCommand("tool.pipe.attr snap innerRange 24");
    penCommand("tool.pipe.attr snap outerRange 40");
}

private int[2] partPixel(int part) {
    double sx, sy; bool found;
    fetchHandlePart(part, sx, sy, found);
    assert(found, format("%s: handle part %d is not drawn", tool, part));
    return [cast(int)(sx + 0.5), cast(int)(sy + 0.5)];
}

/// Part `part` pressed `off` px right of its anchor and dragged by the cell's
/// `drag_px` in 2 px events; `probe` read after each event count in `at`.
private double[] drag(int part, int off, JSONValue c, int[] at, double delegate() probe) {
    const int dx = cast(int)num(c["drag_px"][0]), dy = cast(int)num(c["drag_px"][1]);
    const int n = (abs(dx) + abs(dy)) / 2, sx = dx / n, sy = dy / n;
    auto cam = fetchCamera();
    int[2] p = partPixel(part);
    p[0] += off;
    playAndWait(buildDragDownLog(cam.vpX, cam.vpY, cam.width, cam.height, p[0], p[1]));
    double[] got;
    int done;
    foreach (k; at ~ n) {
        if (k > done)
            playAndWait(buildDragMotionLog(cam.vpX, cam.vpY, cam.width, cam.height,
                p[0] + sx * done, p[1] + sy * done, p[0] + sx * k, p[1] + sy * k, k - done));
        done = k;
        if (k < n) got ~= probe();
    }
    if (fetchSnapLast()["snapped"].type != JSONType.true_)
        fails ~= format("%s part %d: the drag's snap is not published", tool, part);
    playAndWait(buildDragUpLog(cam.vpX, cam.vpY, cam.width, cam.height, p[0] + dx, p[1] + dy));
    return got;
}

private void premise(int[2] p, Vec3 w, string what) {
    const q = worldPixel(Vec3(w.x + planeX, w.y, w.z));
    assert(abs(p[0] - q[0]) <= 1 && abs(p[1] - q[1]) <= 1,
        format("%s rig: %s expected at %s, found at %s", tool, what, q, p));
}

private void expect(string cell, double got, double want) {
    if (!(abs(got - want) <= kTol))
        fails ~= format("%s: expected %.4f, got %.6f", cell, want, got);
}

/// A size / height cell: the dragged extent and the held
/// one; the cell's step table on the extent it names.
private void sizeCell(string id, string t, int part) {
    auto c = fx["cases"][id];
    const string cell = planeX != 0 ? id ~ "@plane-x1" : id;
    const bool height = ("expect_y_extent" in c) !is null;
    rig(t, c, height);
    auto cen = c["cen"].array;
    const ext0 = height ? yExtent() : xExtent();
    premise(partPixel(part), height ? Vec3(0, cast(float)ext0[1], 0)
        : Vec3(cast(float)ext0[1], cast(float)num(cen[1]), 0), "size handle");
    const string tbl = height ? "max_y_at_step" : "min_x_at_step";
    int[] at;
    double[] want;
    if (tbl in c)
        foreach (k; [5, 10, 12, 15]) { at ~= k; want ~= num(c[tbl][format("%d", k)]); }
    const got = drag(part, 0, c, at, () => height ? yExtent()[1] : xExtent()[0]);
    foreach (i, k; at) expect(format("%s step %d", cell, k), got[i], want[i]);
    const e = height ? yExtent() : xExtent();
    auto w = c[height ? "expect_y_extent" : "expect_x_extent"].array;
    expect(cell ~ " max", e[1], num(w[1]));
    expect(cell ~ " min", e[0], num(w[0]));
    penCommand("tool.set " ~ t ~ " off");
    if (planeX != 0) penCommand("workplane.reset");
    ++ran;
}

/// A mover cell: part 10 (+X arrow) or 13 (centre box) pressed `off` px right.
private void moverCell(string id, string t, int part, int off = 0) {
    auto c = fx["cases"][id];
    rig(t, c, false);
    const s0 = xExtent()[1] - qa("cenX");
    const p = partPixel(part), o = worldPixel(Vec3(qa("cenX"), qa("cenY"), qa("cenZ")));
    assert(part == 13 ? abs(p[0] - o[0]) <= 1 && abs(p[1] - o[1]) <= 1
                      : p[0] - o[0] > 20 && abs(p[1] - o[1]) <= 1,
        format("%s rig: part %d must be the %s (centre %s, part %s)", tool, part,
               part == 13 ? "centre box on the centre" : "+X arrow right of the centre", o, p));
    int[] at;
    double[] want;
    if ("cen_x_at_step" in c)
        foreach (k; [5, 10, 12, 15]) { at ~= k; want ~= num(c["cen_x_at_step"][format("%d", k)]); }
    const got = drag(part, off, c, at, () => qa("cenX"));
    foreach (i, k; at) expect(format("%s step %d", id, k), got[i], want[i]);
    auto w = c["expect_cen"].array;
    expect(id ~ " cenX", qa("cenX"), num(w[0]));
    expect(id ~ " cenY", qa("cenY"), num(w[1]));
    expect(id ~ " cenZ", qa("cenZ"), num(w[2]));
    expect(id ~ " size kept", xExtent()[1] - qa("cenX"), s0);
    penCommand("tool.set " ~ t ~ " off");
    ++ran;
}

unittest {
    fx = parseJSON(readText("tests/fixtures/handle_grid_slow.json"));
    sizeCell("primitive-size-grid-slow", "prim.sphere", 0);
    sizeCell("primitive-size-offcentre-grid-slow", "prim.sphere", 0);
    planeX = 1;
    sizeCell("primitive-size-grid-slow", "prim.sphere", 0);
    planeX = 0;
    moverCell("primitive-mover-grid-slow", "prim.sphere", 10);
    moverCell("primitive-mover-free-grid-slow", "prim.sphere", 13);
    sizeCell("cylinder-height-grid-slow", "prim.cylinder", 2);
    sizeCell("cone-size-grid-offcentre", "prim.cone", 0);
    sizeCell("capsule-size-grid-offcentre", "prim.capsule", 0);
    sizeCell("torus-size-grid-offcentre", "prim.torus", 0);
    sizeCell("torus-height-grid-offcentre", "prim.torus", 2);
    moverCell("cone-mover-axis-grid", "prim.cone", 10);
    moverCell("capsule-mover-axis-grid", "prim.capsule", 10);
    moverCell("torus-mover-axis-grid", "prim.torus", 10);
    moverCell("cone-mover-free-grid", "prim.cone", 13);
    moverCell("capsule-mover-free-grid", "prim.capsule", 13);
    moverCell("torus-mover-free-grid", "prim.torus", 13);
    moverCell("torus-mover-free-grid-pressoff", "prim.torus", 13, 2);

    assert(ran == 17, format("population: %d cells ran, expected 17", ran));
    string[] names;
    foreach (f; fails) {
        const n = f[0 .. f.indexOf(':') < 0 ? f.length : f.indexOf(':')];
        if (!names.canFind(n)) names ~= n;
    }
    assert(fails.length == 0, format("%d red (%-(%s, %)):\n  %-(%s\n  %)", names.length, names, fails));
}
