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

// The line and options, written identically in both modes. The ORDER is for
// the live mode: a panel edit re-cuts only while a cut sits on the mesh, so
// every intermediate line must still cross the cube. From the dragged belt
// (about (-0.6,0,0)..(0.6,0,0)) the steps are: Y to 0, start Z, end Z (a
// diagonal through the cube), start X, end X (the final line x = 0.13).
void writeLineAndOptions(string split, string gap) {
    cmd("tool.attr mesh.sliceTool axis y");
    cmd("tool.attr mesh.sliceTool startY 0");
    cmd("tool.attr mesh.sliceTool endY 0");
    cmd("tool.attr mesh.sliceTool startZ -0.9");
    cmd("tool.attr mesh.sliceTool endZ 0.9");
    cmd("tool.attr mesh.sliceTool startX 0.13");
    cmd("tool.attr mesh.sliceTool endX 0.13");
    cmd("tool.attr mesh.sliceTool split " ~ split);
    cmd("tool.attr mesh.sliceTool gap " ~ gap);
}

// LIVE: a real drag lays a slice on the mesh (the session's baseline), the
// panel edits re-cut it from that baseline, the drop commits one entry.
JSONValue liveModel(string split, string gap) {
    resetCube();
    cmd("history.clear");
    const d0 = undoDepth();
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
    assert(getModel()["vertices"].array.length > 8,
        "live: the drag laid no slice on the cube — panel edits would not re-preview");
    writeLineAndOptions(split, gap);
    settle();
    cmd("tool.set mesh.sliceTool off");
    settle();
    // Measured: the activation and the dropped slice are two entries.
    assert(undoDepth() == d0 + 2, format("live: recorded %s entries, expected 2 "
                                         ~ "(activate + slice): %s", undoDepth() - d0, undoList()));
    return getModel();
}

// HEADLESS: activate, write the same values, apply (one cut, no baseline).
JSONValue headlessModel(string split, string gap) {
    resetCube();
    cmd("history.clear");
    const d0 = undoDepth();
    cmd("tool.set mesh.sliceTool on");
    settle();
    writeLineAndOptions(split, gap);
    cmd("tool.doApply");
    cmd("tool.set mesh.sliceTool off");
    settle();
    // Measured: the activation and the apply are two entries on this path.
    assert(undoDepth() == d0 + 2, format("headless: recorded %s entries, expected 2 "
                                         ~ "(activate + apply): %s",
                                         undoDepth() - d0, undoList()));
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
    static struct Case { string split, gap; size_t verts, faces; }
    const Case[] cases = [
        Case("1", "0.2", 16, 12),   // split + gap: the two-cut route
        Case("0", "0.2", 16, 14),   // gap without split: two parallel cuts
    ];
    assert(cases.length == 2);
    foreach (c; cases) {
        const what = format("split %s gap %s", c.split, c.gap);
        auto live = liveModel(c.split, c.gap);
        auto head = headlessModel(c.split, c.gap);
        const lv = live["vertices"].array.length, lf = live["faces"].array.length;
        const hv = head["vertices"].array.length, hf = head["faces"].array.length;
        // PIN first, both modes in one message: a change of the one operation
        // must show in BOTH, which is what proves both reach it.
        assert(lv == c.verts && lf == c.faces && hv == c.verts && hf == c.faces,
            format("%s: expected %sv/%sf in both modes; live %sv/%sf, headless %sv/%sf",
                   what, c.verts, c.faces, lv, lf, hv, hf));
        assertSameModel(live, head, what);
    }
}
