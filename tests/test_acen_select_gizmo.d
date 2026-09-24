// Move under the Selection action centre: the gizmo must not jump DURING a drag
// (item 13; fixture `selection_centre_move` of
// tests/fixtures/editor_attrs_acen_laws_w17.json; gaps 198/199; tasks 7133/7134).
//
// The measured law: the centre is the bounding-box centre of the selection's
// vertices, taken at the run's start and FROZEN for the run; the drawn handle is
// `c + M*T` on EVERY increment with residual 0 and slope 1. A press on an arm
// continues the run; a press off every handle restarts it on the MOVED
// selection, so the handle does not move at that press either.
//
// WHY THE TRAJECTORY AND NOT THE END POINT. Under a rigid translate with no
// falloff every "where is the handle" law converges on `c + T` after release, so
// only the per-increment trace discriminates; and `c` itself is only visible on
// an ASYMMETRIC rig: the selected x = 0, 1, 5 put the box centre at 2.5 and the
// vertex mean at 2.0 (2.3 / 2.0 on the polygon rig). `M*T` is the handle's world
// displacement, which under a rigid move equals the world shift `D_k` of any
// selected vertex, so the per-step assert `|h_k - (c0 + D_k)|` does not depend
// on whether OUR axis frame matches the reference's (a separate question, gap
// 199, recorded below and not asserted).
//
// The handle is read from /api/tool/state `pivot` — the Move bank's handler
// centre, the point the gizmo is DRAWN at, in world units. /api/tool/handles
// only publishes screen anchors (pixels), which cannot resolve 1e-4 m.

import edge_extend_gesture_helpers : cmd, cmdId, toolState, model, num, vtx,
    press, motion, release, settle, topScreen, Px;
import http_client : getJson, postJson;
import std.conv : to;
import std.file : readText;
import std.format : format;
import std.json;
import std.math : abs, sqrt;

void main() {}

private alias V3 = double[3];

private V3 sub(V3 a, V3 b) { return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]; }
private V3 add(V3 a, V3 b) { return [a[0] + b[0], a[1] + b[1], a[2] + b[2]]; }
private double len(V3 a) { return sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]); }
private V3 vec(JSONValue v) { auto a = v.array; return [num(a[0]), num(a[1]), num(a[2])]; }

enum int kIncPx = 4;
enum double kTol = 1e-4;

JSONValue cell(string mode) {
    auto fx = parseJSON(readText("tests/fixtures/editor_attrs_acen_laws_w17.json"));
    return fx["selection_centre_move"]["cells"][mode];
}

/// The drawn handle (world): the Move bank's handler centre.
V3 handle() { return vec(toolState()["pivot"]); }

/// Strip in XZ, x lines x0 .. x0+6 (6 lines, 5 quads) for v/e, x0 = 0; the
/// polygon rig uses 7 lines from -0.5. Index = xi*2 + zi — the fixture's own
/// `vertices_before` order. Faces wound so their normal is +Y (toward the top
/// camera).
void loadStrip(double x0, int lines) {
    string verts = "[";
    foreach (xi; 0 .. lines) foreach (zi; 0 .. 2) {
        if (verts.length > 1) verts ~= ",";
        verts ~= format("[%s,0,%d]", x0 + xi, zi);
    }
    verts ~= "]";
    string faces = "[";
    foreach (xi; 0 .. lines - 1) {
        if (faces.length > 1) faces ~= ",";
        faces ~= format("[%d,%d,%d,%d]", xi * 2, xi * 2 + 1, (xi + 1) * 2 + 1, (xi + 1) * 2);
    }
    faces ~= "]";
    cmdId("scene.loadMesh", `{"vertices":` ~ verts ~ `,"faces":` ~ faces ~ `}`);
}

int edgeOf(int a, int b) {
    foreach (i, e; model()["edges"].array) {
        long p = e.array[0].integer, q = e.array[1].integer;
        if ((p == a && q == b) || (p == b && q == a)) return cast(int) i;
    }
    assert(false, format("rig edge (%d,%d) missing", a, b));
}

/// Reset, rig, selection, Move with the Selection centre, no falloff, no
/// symmetry, top ortho centred on the strip. Returns the index of one selected
/// vertex (the D_k probe).
int armRig(string mode) {
    auto r = postJson("/api/command", `{"id":"scene.reset"}`);
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    auto c = cell(mode);
    int probe;
    if (mode == "p") {
        loadStrip(-0.5, 7);
        cmdId("mesh.select", `{"mode":"polygons","indices":[0,1,5]}`);
        probe = 0;
    } else if (mode == "e") {
        loadStrip(0, 6);
        cmdId("mesh.select", format(`{"mode":"edges","indices":[%d,%d,%d]}`,
            edgeOf(0, 1), edgeOf(2, 3), edgeOf(10, 11)));
        probe = 0;
    } else {
        loadStrip(0, 6);
        cmdId("mesh.select", `{"mode":"vertices","indices":[0,2,10]}`);
        probe = 0;
    }
    // Floor: the rig is the fixture's rig, vertex for vertex.
    auto m = model();
    auto vb = c["vertices_before"].array;
    assert(m["vertices"].array.length == vb.length,
        format("rig floor (%s): %d vertices, fixture has %d", mode, m["vertices"].array.length, vb.length));
    foreach (i, v; vb) {
        immutable V3 a = vtx(m, i), b = vec(v);
        assert(len(sub(a, b)) <= 1e-6, format("rig floor (%s): vertex %d is %s, fixture %s", mode, i, a, b));
    }
    cmd("tool.set move on");
    cmd("actr.select");
    cmd("tool.pipe.attr falloff type none");
    cmd("tool.pipe.attr symmetry enabled false");
    cmd("viewport.view Top");
    r = postJson("/api/camera", `{"focus":{"x":2.5,"y":0,"z":0.5}}`);
    assert(r["status"].str == "ok", "camera focus failed: " ~ r.toString);
    assert(getJson("/api/camera")["projKind"].str == "Ortho", "rig premise: top view must be orthographic");
    cmd("history.clear");
    settle(250);
    // Floor: falloff and symmetry inactive, the centre mode is Selection.
    bool sawFalloff, sawSym, sawAcen;
    foreach (st; getJson("/api/toolpipe")["stages"].array) {
        if (st["id"].str == "falloff") {
            sawFalloff = true;
            assert(st["attrs"]["type"].str == "none", "rig premise: falloff is on: " ~ st.toString);
        } else if (st["id"].str == "symmetry") {
            sawSym = true;
            assert(st["attrs"]["enabled"].str == "false", "rig premise: symmetry is on: " ~ st.toString);
        } else if (st["id"].str == "actionCenter") {
            sawAcen = true;
            assert(st["attrs"]["mode"].str == "select", "rig premise: centre mode is not select: " ~ st.toString);
        }
    }
    assert(sawFalloff && sawSym && sawAcen, "rig premise: falloff/symmetry/actionCenter stage missing");
    assert(toolState()["tool"].str == "xfrm", "rig premise: Move is not the active tool");
    return probe;
}

/// Screen pixel of a world point in the top ortho view (y ignored).
Px px(V3 w) { return topScreen(w[0], w[2]); }

/// The two in-plane arms of OUR gizmo in the top view, located from the
/// published screen anchors (parts 0..2 = X, Y, Z arrows): `horiz` is the arm
/// whose screen direction is most horizontal, `vert` the most vertical. The
/// press point is 70 % of the way from the handle centre to the arm's anchor.
void arms(out Px horiz, out int horizAxis, out Px vert, out int vertAxis) {
    immutable Px c = px(handle());
    double bestH = 0, bestV = 0;
    foreach (p; getJson("/api/tool/handles")["handles"]["parts"].array) {
        immutable int part = cast(int) p["part"].integer;
        if (part < 0 || part > 2 || p["screen"].type == JSONType.null_) continue;
        immutable double dx = num(p["screen"][0]) - c.x, dy = num(p["screen"][1]) - c.y;
        if (sqrt(dx * dx + dy * dy) < 20) continue;   // an arm seen end-on
        immutable Px at = Px(c.x + cast(int)(0.7 * dx), c.y + cast(int)(0.7 * dy));
        if (abs(dx) > abs(dy) && abs(dx) > bestH) { bestH = abs(dx); horiz = at; horizAxis = part; }
        if (abs(dy) > abs(dx) && abs(dy) > bestV) { bestV = abs(dy); vert = at; vertAxis = part; }
    }
    assert(bestH > 0 && bestV > 0, "no in-plane arms found in /api/tool/handles: "
        ~ getJson("/api/tool/handles").toString);
}

/// One drag of `n` increments of (dx, dy) px from `at`; the handle is compared
/// with `c0 + D_k` after EVERY increment. Returns the handle after release.
V3 dragAndTrace(string mode, string which, Px at, int wantAxis, int n, int dx, int dy,
                int probe, V3 c0, V3 probeAtStart, ref string trace,
                V3 offGizmoBefore = [double.nan, 0, 0]) {
    import std.math : isNaN;
    press(at);
    if (wantAxis >= 0)
        assert(cast(int) toolState()["dragAxis"].integer == wantAxis,
            format("%s %s: the press did not grab arm %d: %s", mode, which, wantAxis, toolState().toString));
    else
        // An off-gizmo press is the screen-plane haul (dragAxis 3, the same
        // value as the centre box) — it must not be one of the three arms.
        assert(cast(int) toolState()["dragAxis"].integer == 3,
            format("%s %s: the off-gizmo press did not start the screen-plane haul: %s", mode, which, toolState().toString));
    if (!isNaN(offGizmoBefore[0])) {
        immutable V3 hp = handle();
        assert(len(sub(hp, offGizmoBefore)) <= kTol,
            format("gizmo jumped at the off-gizmo press (%s): %s before the press, %s after",
                mode, offGizmoBefore, hp));
    }
    Px cur = at;
    double lastD = 0;
    int checked;
    foreach (k; 1 .. n + 1) {
        cur = Px(cur.x + dx, cur.y + dy);
        motion(cur, dx, dy);
        immutable V3 d = sub(vtx(model(), probe), probeAtStart);
        immutable V3 h = handle();
        trace ~= format(" %s k=%d D=%s h=%s;", which, k, d, h);
        // Floor: the drag really moves the selection, strictly further each step.
        assert(len(d) > lastD, format("%s %s: |D_%d| = %g did not grow (prev %g) — the drag is not "
            ~ "moving the selection, so this increment carries no signal", mode, which, k, len(d), lastD));
        lastD = len(d);
        immutable V3 want = add(c0, d);
        assert(len(sub(h, want)) <= kTol,
            format("gizmo jumped under Selection centre at increment %d (%s): drag %s, handle %s, "
                ~ "expected c0 + D = %s (c0 %s, D %s); trace:%s", k, mode, which, h, want, c0, d, trace));
        ++checked;
    }
    assert(checked == n, format("%s %s: %d increments checked, expected %d", mode, which, checked, n));
    release(cur);
    return handle();
}

/// The frame record for gap 199: our axes before the press against the
/// fixture's `axis_matrix_rows`, per row up to sign. NOT an assert (S12 plan:
/// a frame difference is not item 13).
string frameParity(string mode) {
    auto ax = getJson("/api/toolpipe/eval")["axis"];
    V3[3] ours = [vec(ax["right"]), vec(ax["up"]), vec(ax["fwd"])];
    auto rows = cell(mode)["axis_matrix_rows"].array[0].array;
    bool match = true;
    foreach (r; 0 .. 3) {
        V3 ref_ = [num(rows[r * 3]), num(rows[r * 3 + 1]), num(rows[r * 3 + 2])];
        immutable double same = len(sub(ours[r], ref_));
        immutable double flip = len(add(ours[r], ref_));
        if (same > 1e-5 && flip > 1e-5) match = false;
    }
    return format("%s: ours right=%s up=%s fwd=%s; parity %s", mode, ours[0], ours[1], ours[2],
        match ? "match" : "differs");
}

/// One whole cell: centre at press, drag 1 (horizontal arm, 10 x 4 px right),
/// drag 2 (vertical arm, 5 x 4 px up — or, for v-off, a press on empty space).
void runCell(string mode) {
    immutable int probe = armRig(mode);
    auto fx = cell(mode);
    immutable V3 c0 = handle();
    immutable V3 fxCentre = vec(fx["steps"].array[0]["centre"]);
    assert(len(sub(c0, fxCentre)) <= kTol,
        format("gizmo centre at press is not the selection box centre (%s): handle %s, fixture %s",
            mode, c0, fxCentre));
    // Record (not assert) the frame parity for gap 199.
    import std.stdio : stderr;
    stderr.writeln("7133 frame ", frameParity(mode));

    Px horiz, vert; int hAxis, vAxis;
    arms(horiz, hAxis, vert, vAxis);
    string trace;
    immutable V3 start1 = vtx(model(), probe);
    immutable V3 h1 = dragAndTrace(mode, "D1", horiz, hAxis, 10, kIncPx, 0, probe, c0, start1, trace);
    immutable V3 afterD1 = sub(vtx(model(), probe), start1);

    if (mode == "v-off") {
        // Second press on EMPTY space: up-left of the handle, off the strip
        // (z < 0 is empty) and off every arm; the drag then continues from it.
        immutable Px h = px(h1);
        immutable Px empty = Px(h.x - 150, h.y - 150);
        immutable V3 start2 = vtx(model(), probe);
        immutable V3 c1 = add(c0, afterD1);   // the restarted run's centre
        dragAndTrace(mode, "D2", empty, -1, 5, 0, -kIncPx, probe, c1, start2, trace, h1);
    } else {
        arms(horiz, hAxis, vert, vAxis);
        dragAndTrace(mode, "D2", vert, vAxis, 5, 0, -kIncPx, probe, c0, start1, trace);
    }
    cmd("tool.set move off");
}

unittest { runCell("v"); }
unittest { runCell("e"); }
unittest { runCell("p"); }
unittest { runCell("v-off"); }
