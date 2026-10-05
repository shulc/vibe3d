// Polygon pen under symmetry (wave plan S6) against the captured cells of
// tests/fixtures/pen_symmetry.json and the mirror rows of pen_merge.json.
// With symmetry on, the stroke's geometry includes its reflection: the mirror
// points follow the originals in click order, the mirror ring is the original's
// ring routine with the reverse decision toggled, and both land in the stroke's
// one undo entry. A point within half the merge distance of the plane is its own
// mirror; a click on a mirror image shares vertices crosswise, the mirror
// positions written last. The plane is latched at the stroke's first click; a
// symmetry change during a stroke closes it on the next frame by the drop rule.
// Under the work plane the mirror plane is the axis plane mapped by the work
// plane's transform twice (captured; a probable reference defect copied by
// owner decision).
//
// Rig: top ortho, focus on y = 1, 420 px/m unless a cell says otherwise (the
// captured 440 cannot fit the A7 press at x -0.75 beside the point at 0.75 in
// our 650 px viewport; 420 keeps the 0.005 m placement quantum, so every
// clicked fixture position is a lattice value and positions compare to 1e-4).
// Counts and rings are exact.
//
// Ours-only cells, constructions stated:
//  - A6-depth: two clicks, `symmetry.toggle`, two frames, no pen input: the
//    stroke is already closed (the close runs in the tool's per-frame update,
//    not at the next press).
//  - toggle-mid-drag: the toggle lands while a point drag is held; the close
//    waits for the release, so the dragged point ends where the drag ends.
// Not a cell (construction argument): a mid-stroke toggle that re-latches the
// plane per event is unreachable — the stroke closes on the first frame after
// the change, before any later event of that stroke could read a new plane.

import drag_helpers : Vec3, buildDragDownLog, buildDragLog,
    buildDragMotionLog, buildDragUpLog, fetchCamera, kPaceLine, playAndWait;
import http_client : frameFence, getJson, postJson;
import pen_rig_helpers;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : abs, round;

void main() {}

private enum double kTol = 1e-4;
private enum int kSymZ = 122, kModCtrl = 64, kModShift = 1;

private double num(JSONValue v) {
    return v.type == JSONType.integer ? cast(double)v.integer
         : v.type == JSONType.uinteger ? cast(double)v.uinteger
         : v.type == JSONType.float_ ? v.floating : double.nan;
}
private Vec3 p(double x, double z, double y = 1) {
    return Vec3(cast(float)x, cast(float)y, cast(float)z);
}
private Vec3[] verts(JSONValue a) {
    Vec3[] r;
    foreach (v; a.array)
        r ~= Vec3(cast(float)num(v[0]), cast(float)num(v[1]), cast(float)num(v[2]));
    return r;
}
private long[][] rings(JSONValue a) {
    long[][] r;
    foreach (f; a.array) {
        long[] ring;
        foreach (e; f.array) ring ~= e.integer;
        r ~= ring;
    }
    return r;
}
private Vec3[] clicks(JSONValue c) {
    Vec3[] r;
    foreach (q; c["clicks_xz_on_plane_y1"].array) r ~= p(num(q[0]), num(q[1]));
    return r;
}

// ---- rig ------------------------------------------------------------------

/// Empty top view, focus `focus` at `ppm`, snapping off, symmetry `axis`
/// (null = off) at `offset`, the pen armed with `merge`.
private void rig(string axis, double offset = 0, bool merge = true,
                 Vec3 focus = Vec3(0, 1, 0), double ppm = 420) {
    penSceneEmpty("Top");
    penCameraAt(focus, ppm);
    penCommand("tool.pipe.attr snap enabled false");
    symmetry(axis, offset);
    penCommand("tool.set pen on");
    if (!merge) penCommand("tool.attr pen merge false");
}
private void symmetry(string axis, double offset = 0, bool workplane = false) {
    penCommand("tool.pipe.attr symmetry enabled " ~ (axis is null ? "false" : "true"));
    penCommand("tool.pipe.attr symmetry axis " ~ (axis is null ? "x" : axis));
    penCommand(format("tool.pipe.attr symmetry offset %.9f", offset));
    penCommand("tool.pipe.attr symmetry useWorkplane " ~ (workplane ? "true" : "false"));
}
private void drop() { penCommand("tool.set pen off"); }
private void toggle() { penCommand("symmetry.toggle"); frameFence(null, 2); }
private void typed(string name, double value) {
    auto r = postJson("/api/script?interactive=true",
        format("tool.attr pen %s %.9f", name, value));
    assert(r["status"].str == "ok", "typed " ~ name ~ " failed: " ~ r.toString);
}
private void key(int sym, int mod) {
    auto cam = fetchCamera();
    playAndWait(format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,`
        ~ `"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~ kPaceLine
        ~ `{"t":50.000,"type":"SDL_KEYDOWN","sym":%d,"scan":0,"mod":%d,"repeat":0}` ~ "\n"
        ~ `{"t":100.000,"type":"SDL_KEYUP","sym":%d,"scan":0,"mod":%d,"repeat":0}` ~ "\n",
        cam.vpX, cam.vpY, cam.width, cam.height, sym, mod, sym, mod));
}
private long depth() { return cast(long)getJson("/api/history")["undo"].array.length; }
/// Press on world point `from`, drag to `to` (screen pixels of both).
private void drag(Vec3 from, Vec3 to) {
    auto cam = fetchCamera();
    auto a = worldPixel(from), b = worldPixel(to);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
        a[0], a[1], b[0], b[1]));
}

// ---- reads ----------------------------------------------------------------

private struct Model { Vec3[] v; long[][] f; }
private Model model() {
    Model m;
    auto j = getJson("/api/model");
    m.v = verts(j["vertices"]);
    m.f = rings(j["faces"]);
    return m;
}
/// The mesh against `want` / `wantF` (null = rings not scored): counts and
/// rings exactly, positions to `tol`.
private string[] compare(string cell, Vec3[] want, long[][] wantF, double tol = kTol) {
    auto m = model();
    if (m.v.length != want.length || (wantF !is null && m.f != wantF))
        return [format("%s: %s vertices, faces %s; expected %s, faces %s", cell,
                       m.v.length, m.f, want.length, wantF)];
    string[] bad;
    foreach (i, w; want) {
        const g = m.v[i];
        if (!(abs(g.x - w.x) <= tol && abs(g.y - w.y) <= tol && abs(g.z - w.z) <= tol))
            bad ~= format("v%s (%.6f, %.6f, %.6f) vs (%.6f, %.6f, %.6f)", i,
                          g.x, g.y, g.z, w.x, w.y, w.z);
    }
    return bad.length ? [format("%s: %-(%s; %)", cell, bad)] : null;
}
private string[] fixture(string cell, JSONValue exp) {
    return compare(cell, verts(exp["vertices"]),
        rings("polygons" in exp.object ? exp["polygons"] : exp["faces"]));
}

/// A fixture case: its axis / offset / merge, its clicks, then `gesture`.
private string[] axisCase(string name, JSONValue c, ref int ran,
                          void delegate() gesture = null, Vec3[] reach = null) {
    auto s = c["symmetry_setup"];
    auto pts = clicks(c);
    Vec3 lo = pts[0], hi = pts[0];      // focus: the centre of what the cell touches
    foreach (q; pts ~ reach) {
        lo.x = q.x < lo.x ? q.x : lo.x; hi.x = q.x > hi.x ? q.x : hi.x;
        lo.z = q.z < lo.z ? q.z : lo.z; hi.z = q.z > hi.z ? q.z : hi.z;
    }
    rig(s["axis"].str, "offset" in s.object ? num(s["offset"]) : 0,
        !("merge" in s.object && s["merge"].type == JSONType.false_),
        p((lo.x + hi.x) / 2, (lo.z + hi.z) / 2));
    clickWorld(pts);
    if (gesture !is null) gesture();
    drop(); ++ran;
    return fixture(name, c["expected"]);
}

unittest {
    auto fx = parseJSON(import("fixtures/pen_symmetry.json"))["cases"];
    auto mc = parseJSON(import("fixtures/pen_merge.json"))["cells"];
    string[] fails;
    int ran;
    auto b1 = clicks(fx["B1"]);

    // ===== must stay green ==================================================
    // A6b: symmetry turned on after the third click, then the drop: no mirror.
    {
        rig(null);
        clickWorld(b1);
        symmetry("x");
        frameFence(null, 2);
        drop(); ++ran;
        fails ~= fixture("A6b", fx["A6b-toggle-drop"]["expected"]);
    }
    // ===== must turn ========================================================
    // A toggle while a point drag is held closes after the release: the
    // dragged point ends at the drag's end (0.75 + 80 px).
    {
        rig(null, 0, true, p(0.5, 0));
        clickWorld(b1);
        auto cam = fetchCamera();
        auto a = worldPixel(b1[2]);
        playAndWait(buildDragDownLog(cam.vpX, cam.vpY, cam.width, cam.height, a[0], a[1]));
        playAndWait(buildDragMotionLog(cam.vpX, cam.vpY, cam.width, cam.height,
            a[0], a[1], a[0] + 42, a[1]));
        toggle();
        playAndWait(buildDragMotionLog(cam.vpX, cam.vpY, cam.width, cam.height,
            a[0] + 42, a[1], a[0] + 84, a[1]));
        playAndWait(buildDragUpLog(cam.vpX, cam.vpY, cam.width, cam.height,
            a[0] + 84, a[1]));
        frameFence(null, 2);
        ++ran;
        fails ~= compare("toggle-mid-drag", [b1[0], b1[1], p(0.95, 0.25)], [[0, 2, 1]]);
        drop();
    }
    // Typed positions never weld with their mirror, near or on the plane.
    foreach (cell, x; ["mirror_typed_half_distance": 0.0017, "mirror_typed_on_plane": 0.0]) {
        rig("x", 0, true, p(0.3, 0));
        clickWorld(p(0.5, 0.2), p(0.5, -0.3), p(0.805, -0.05));
        typed("currentPoint", 0);
        typed("posX", x);
        drop(); ++ran;
        fails ~= fixture(cell, mc[cell]["expected"]);
    }

    // B1 / A5: the mirror and its ring, axes X / Y / Z and an offset plane.
    foreach (cell; ["B1", "A5-symY", "A5-symZ", "A5-symXoff"])
        fails ~= axisCase(cell, fx[cell], ran);
    // B3 / B4 / B4m: crosswise sharing, an on-plane point, merge off.
    foreach (cell; ["B3", "B4", "B4m"])
        fails ~= axisCase(cell, fx[cell], ran);
    // B6: the mirror follows a drag and typed positions.
    fails ~= axisCase("B6d", fx["B6d"], ran, () => drag(b1[2], p(0.85, 0.35)),
                      [p(0.85, 0.35)]);
    fails ~= axisCase("B6n", fx["B6n"], ran, () => typed("posX", 0.9));
    fails ~= axisCase("B6n_cur1", fx["B6n_cur1"], ran, {
        typed("currentPoint", 1);
        typed("posX", 0.6);
    });
    // A7: a press on m(p2) adds a point; dragged 38 px (0.09 m at 420 px/m,
    // the captured 40 px at 440), the weld holds. Merge off: nothing welds.
    fails ~= axisCase("A7", fx["A7-mirror-handle"], ran,
        () => drag(p(-0.75, 0.25), p(-0.66, 0.25)), [p(-0.75, 0.25)]);
    {
        rig("x", 0, false);
        clickWorld(b1);
        drag(p(-0.75, 0.25), p(-0.66, 0.25));
        drop(); ++ran;
        fails ~= fixture("mirror_press_drag_merge_off",
                         mc["mirror_press_drag_merge_off"]["expected"]);
    }
    // The self-weld gap: 2|x| against 3 px of world at 622 px/m (0.00482 m).
    foreach (cell; ["mirror_gap_click_x0.002", "mirror_gap_click_x-0.002",
                    "mirror_gap_click_x0.004", "mirror_gap_click_x0.006"]) {
        rig("x", 0, true, p(0.3, 0.03), 440 * 1.41421356);
        const x = num(mc[cell]["expected"]["vertices"][0][0]);
        clickWorld(p(x, 0.002), p(0.588, -0.292), p(0.588, 0.352));
        drop(); ++ran;
        fails ~= fixture(cell, mc[cell]["expected"]);
    }
    // A8: one undo removes the stroke and its mirror; one redo restores both.
    {
        auto c = fx["A8-undo"];
        rig("x");
        clickWorld(b1);
        drop(); ++ran;
        fails ~= fixture("A8 after drop", c["expected_after_drop"]);
        const d0 = depth();
        key(kSymZ, kModCtrl);
        fails ~= fixture("A8 after undo", c["expected_after_one_undo"]);
        key(kSymZ, kModCtrl | kModShift);
        fails ~= fixture("A8 after redo", c["expected_after_redo"]);
        if (d0 != 1) fails ~= format("A8: %s history rows after the drop, expected 1", d0);
    }
    // A6: the toggle after the second click closes the 2-point stroke as an
    // edge face; the third click starts a new stroke, which the drop discards.
    {
        rig(null);
        clickWorld(b1[0], b1[1]);
        toggle();
        clickWorld(b1[2]);
        drop(); ++ran;
        fails ~= fixture("A6", fx["A6-toggle"]["expected"]);
    }
    // A6-depth: the stroke closes AT the toggle — a history row and the edge
    // face exist before any further pen input.
    {
        rig(null);
        clickWorld(b1[0], b1[1]);
        const d0 = depth();
        toggle(); ++ran;
        const d1 = depth();
        if (d1 != d0 + 1)
            fails ~= format("A6-depth: history %s -> %s across the toggle, expected +1", d0, d1);
        fails ~= compare("A6-depth", [b1[0], b1[1]], [[0, 1]]);
        drop();
    }
    // A5-symWP2: symmetry X in a pinned work plane (origin (0.3, 0, 0), rotZ
    // 30). Points typed to the fixture's plane-local values; the mirror plane
    // is the axis plane mapped by the plane's transform twice: normal
    // (0.5, 0.866, 0) through (0.5598, 0.15, 0). Rings are not scored (the
    // facing was decided from the click pixels).
    {
        auto c = fx["A5-symWP2"];
        penSceneEmpty("Top");
        penCommand("workplane.edit cenX:0.3 cenY:0 cenZ:0 rotX:0 rotY:0 rotZ:30");
        penCameraAt(p(0, 0), 420);
        penCommand("tool.pipe.attr snap enabled false");
        symmetry("x", 0, true);
        penCommand("tool.set pen on");
        clickWorld(p(-0.2, -0.6, 0), p(0.3, -0.6, 0), p(0.3, 0.6, 0));
        foreach (i, q; clicks(c)) {
            typed("currentPoint", i);
            typed("posX", q.x); typed("posY", 1); typed("posZ", q.z);
        }
        drop(); ++ran;
        fails ~= compare("A5-symWP2", verts(c["expected"]["vertices"]), null);
        penCommand("workplane.reset");
    }

    symmetry(null);
    // Floor: 1 stay-green + 23 turning cells (A8 reads three moments).
    assert(ran == 24, format("ran %s cells, pinned 24", ran));
    assert(fails.length == 0, format("%s failure(s):\n  %-(%s\n  %)", fails.length, fails));
}
