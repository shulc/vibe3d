// Slice tool (mesh.sliceTool): the interactive slice and the scripted apply
// produce the SAME mesh for the same line and options (task 9431).
//
// Both run one cut operation (`sliceCut`): the live session through its
// baseline re-cut (drag, then panel edits re-preview, then the drop commits),
// the headless path through `applyHeadless` (`tool.attr …; tool.doApply`).
// The line is written through `tool.attr` in BOTH modes with the same literals,
// and the axis is locked to world Y, so the plane does not depend on the
// camera-picked drag plane: n = normalize(cross(end - start, Y)) = +-X through
// x = 0.13, y = 0. Each mode is pinned to its measured counts first (so a change of
// the one operation reddens both modes, not just their equality), then the two
// models are compared vertex by vertex at a float bound (the JSON wire prints
// at its own precision; the operation itself is bit-identical, see the
// equivalence probe recorded on task 9431).

import http_client : testBaseUrl, quiesce;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.math  : fabs;
import std.format : format;

import drag_helpers;   // Vec3, Viewport, fetchCamera, viewportFromCamera, projectToWindow, buildDragLog, playAndWait

void main() {}

alias BASE = testBaseUrl;

void cmd(string s) {
    auto resp = cast(string) post(BASE ~ "/api/command", s);
    assert(parseJSON(resp)["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ resp);
}
void resetCube() {
    auto resp = cast(string) post(BASE ~ "/api/command", commandBody("scene.reset"));
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset failed: " ~ resp);
}
JSONValue getModel() { return parseJSON(cast(string) get(BASE ~ "/api/model")); }
size_t undoDepth() {
    return parseJSON(cast(string) get(BASE ~ "/api/history"))["undo"].array.length;
}
string undoList() { return parseJSON(cast(string) get(BASE ~ "/api/history"))["undo"].toString; }
void settle() { quiesce(); }

void scr(Vec3 w, const ref Viewport vp, out int px, out int py) {
    float fx, fy;
    assert(projectToWindow(w, vp, fx, fy), "world point projected off-screen");
    px = cast(int)(fx + 0.5f);
    py = cast(int)(fy + 0.5f);
}

// One configuration: setup commands (before activation), then the tool attrs,
// written identically in both modes. The attr ORDER is for the live mode: a
// panel edit re-cuts only while a cut sits on the mesh, so every intermediate
// line must still cross the mesh.
struct Case { string name; string[] setup; string[] attrs; size_t verts, faces; }

void runSetup(const Case c) {
    resetCube();
    foreach (s; c.setup) cmd(s);
    cmd("history.clear");
}
void writeAttrs(const Case c) {
    foreach (a; c.attrs) cmd("tool.attr mesh.sliceTool " ~ a);
}

// LIVE: a real drag lays a slice on the mesh (the session's baseline), the
// panel edits re-cut it from that baseline, the drop commits.
JSONValue liveModel(const Case c) {
    runSetup(c);
    const d0 = undoDepth();
    const v0 = getModel()["vertices"].array.length;
    cmd("tool.set mesh.sliceTool on");
    settle();
    auto vp = viewportFromCamera(fetchCamera(BASE));
    int ax, ay, bx, by;
    // A belt along world X through the origin: on either camera-picked plane
    // (XY or XZ) it lands near y = z = 0 and cuts; the attrs then move it.
    scr(Vec3(-0.6f, 0, 0), vp, ax, ay);
    scr(Vec3( 0.6f, 0, 0), vp, bx, by);
    playAndWait(buildDragLog(vp.x, vp.y, vp.width, vp.height, ax, ay, bx, by, 20, 0), BASE);
    settle();
    assert(getModel()["vertices"].array.length > v0,
        c.name ~ ": live: the drag laid no slice — panel edits would not re-preview");
    writeAttrs(c);
    settle();
    cmd("tool.set mesh.sliceTool off");
    settle();
    // Measured: the activation and the dropped slice are two entries.
    assert(undoDepth() == d0 + 2, format("%s: live: recorded %s entries, expected 2 "
        ~ "(activate + slice): %s", c.name, undoDepth() - d0, undoList()));
    return getModel();
}

// HEADLESS: activate, write the same values, apply (one cut, no baseline).
JSONValue headlessModel(const Case c) {
    runSetup(c);
    const d0 = undoDepth();
    cmd("tool.set mesh.sliceTool on");
    settle();
    writeAttrs(c);
    cmd("tool.doApply");
    cmd("tool.set mesh.sliceTool off");
    settle();
    // Measured: the activation and the apply are two entries on this path.
    assert(undoDepth() == d0 + 2, format("%s: headless: recorded %s entries, expected 2 "
        ~ "(activate + apply): %s", c.name, undoDepth() - d0, undoList()));
    return getModel();
}

void assertSameModel(JSONValue a, JSONValue b, string what) {
    auto va = a["vertices"].array, vb = b["vertices"].array;
    auto fa = a["faces"].array,    fb = b["faces"].array;
    assert(va.length == vb.length && fa.length == fb.length,
        format("%s: live %sv/%sf vs headless %sv/%sf", what,
               va.length, fa.length, vb.length, fb.length));
    foreach (i; 0 .. va.length)
        foreach (c; 0 .. 3) {
            const x = va[i].array[c].floating, y = vb[i].array[c].floating;
            assert(fabs(x - y) <= 1e-5, format("%s: vertex %s axis %s live %s vs headless %s",
                                               what, i, c, x, y));
        }
    foreach (i; 0 .. fa.length)
        assert(fa[i].toString == fb[i].toString,
            format("%s: face %s live %s vs headless %s", what, i, fa[i], fb[i]));
}

unittest {
    // Measured counts per configuration (task 9431, both modes on main).
    const Case[] cases = [
        // Split + caps + gap on a twice-subdivided cube, an oblique infinite
        // plane (the parameters of test_fixture_slice_subdiv_gap): the
        // two-cut route, which a cube cannot tell from the single-cut slide.
        // The axis lock comes LAST: the dragged belt runs along X, which an
        // X lock would make degenerate.
        Case("split-caps-gap dense", ["mesh.subdivide", "mesh.subdivide"],
             ["infinite 1", "split 1", "caps 1", "gap 0.415", "gapSide center",
              "startX 0", "startY 0.4", "startZ 0.61",
              "endX 0", "endY -1.14", "endZ -1.89", "axis x"], 92, 74),
        // Gap without split on the cube: two parallel cuts. From the belt the
        // line steps Y to 0, start Z, end Z (a diagonal), start X, end X.
        Case("gap-nosplit cube", [],
             ["axis y", "startY 0", "endY 0", "startZ -0.9", "endZ 0.9",
              "startX 0.13", "endX 0.13", "split 0", "gap 0.2"], 16, 14),
    ];
    assert(cases.length == 2);
    foreach (c; cases) {
        auto live = liveModel(c);
        auto head = headlessModel(c);
        const lv = live["vertices"].array.length, lf = live["faces"].array.length;
        const hv = head["vertices"].array.length, hf = head["faces"].array.length;
        // PIN first, both modes in one message: a change of the one operation
        // must show in BOTH, which is what proves both reach it.
        assert(lv == c.verts && lf == c.faces && hv == c.verts && hf == c.faces,
            format("%s: expected %sv/%sf in both modes; live %sv/%sf, headless %sv/%sf",
                   c.name, c.verts, c.faces, lv, lf, hv, hf));
        assertSameModel(live, head, c.name);
    }
}

// A headless line that misses the mesh is REFUSED: no edit, no history entry.
unittest {
    resetCube();
    cmd("history.clear");
    cmd("tool.set mesh.sliceTool on");
    settle();
    foreach (a; ["axis y", "startX 5", "startY 0", "startZ -0.9",
                 "endX 5", "endY 0", "endZ 0.9", "infinite 1"])
        cmd("tool.attr mesh.sliceTool " ~ a);
    const d0 = undoDepth();
    auto r = parseJSON(cast(string) post(BASE ~ "/api/command", "tool.doApply"));
    settle();
    assert(r["status"].str == "error" && undoDepth() == d0
           && getModel()["vertices"].array.length == 8,
        format("a missing plane must refuse the apply: %s, depth %s -> %s, %sv",
               r.toString, d0, undoDepth(), getModel()["vertices"].array.length));
    cmd("tool.set mesh.sliceTool off");
}

// The headless angle snap is a pre-step of the apply: the clip span of the one
// operation is the SNAPPED line. A short line ~19 deg off X snaps onto X (45 deg
// quantum) and ends inside the cube at x = 0.3, so the clipped cut terminates
// there (the unsnapped end would project to x = 0.235).
unittest {
    resetCube();
    cmd("tool.set mesh.sliceTool on");
    settle();
    foreach (a; ["snap 1", "snapAngle 45", "startX -0.9", "startY 0", "startZ 0",
                 "endX 0.2346", "endY 0", "endZ 0.3907"])
        cmd("tool.attr mesh.sliceTool " ~ a);
    cmd("tool.doApply");
    cmd("tool.set mesh.sliceTool off");
    settle();
    double maxX = -9;
    size_t onPlane;
    foreach (v; getModel()["vertices"].array) {
        const x = v.array[0].floating, z = v.array[2].floating;
        if (fabs(z) < 1e-4) { ++onPlane; if (x > maxX) maxX = x; }
    }
    assert(onPlane > 0 && fabs(maxX - 0.3) < 1e-4,
        format("snapped clip span: %s cut vertices, the farthest at x = %s, expected 0.3",
               onPlane, maxX));
}
