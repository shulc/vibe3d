// Slice tool (mesh.sliceTool) KEEP-SELECTION end-to-end lock (cut-keep-split-
// faces-selected task).
//
// The shared chord-cut kernel (Mesh.rebuildFacesWithChordSplits) now INHERITS
// each parent face's Marks.Select bit onto every emitted slot instead of
// unconditionally clearing it: a selected parent's split halves BOTH stay
// selected, an unselected parent's halves stay unselected, and nothing
// selected before the cut still yields nothing selected after (see the
// mesh.d unittest block for the kernel-level lock). This test drives the
// SAME behavior through the full tool -> command -> kernel -> /api/selection
// round-trip, headlessly, via the mesh.sliceTool doApply sequence
// (tests/fixture_helpers.d:536-595) rather than an interactive drag.
//
// Case (mirrors tests/fixtures/slice_selection.json "restricted_two_faces"):
// a fresh cube's front (z=-0.5, face 0) and back (z=+0.5, face 1) polygons
// are selected, then an x=0 infinite plane cut (line along Z, default XZ/+Y
// work plane) restricts the split to those two faces — 8f -> 12v/8f, with the
// two crossed-but-unselected top/bottom neighbours absorbing a shared
// crossing vertex whole. Per the fix, BOTH halves of EACH selected parent
// stay selected: 2 selected in -> 4 selected out.

import http_client : testBaseUrl, quiesce;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.format : format;
import core.thread : Thread;
import core.time   : dur;

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

void selectPolygons(int[] indices) {
    string idxJson = "[";
    foreach (k, v; indices) { if (k) idxJson ~= ","; idxJson ~= format("%d", v); }
    idxJson ~= "]";
    auto resp = cast(string) post(BASE ~ "/api/command", commandBody("mesh.select", format(`{"mode":"polygons","indices":%s}`, idxJson)));
    assert(parseJSON(resp)["status"].str == "ok", "/api/select failed: " ~ resp);
}

JSONValue getModel()     { return parseJSON(cast(string) get(BASE ~ "/api/model")); }
size_t vertCount() { return getModel()["vertices"].array.length; }
size_t faceCount() { return getModel()["faces"].array.length; }

JSONValue getSelection() { return parseJSON(cast(string) get(BASE ~ "/api/selection")); }
size_t selCount(string key) { return getSelection()[key].array.length; }


void settle() { quiesce(); }   // post-command settle guard

// Headless x=0 infinite plane slice (mirrors tests/fixture_helpers.d's
// "slice" step / tests/fixtures/slice_selection.json): line along Z through
// the origin, default XZ/+Y work plane -> normal ||X -> plane x=0.
void sliceXZeroInfinite() {
    cmd("tool.set mesh.sliceTool on");
    cmd("tool.attr mesh.sliceTool infinite 1");
    cmd("tool.attr mesh.sliceTool startX 0");
    cmd("tool.attr mesh.sliceTool startY 0");
    cmd("tool.attr mesh.sliceTool startZ -1");
    cmd("tool.attr mesh.sliceTool endX 0");
    cmd("tool.attr mesh.sliceTool endY 0");
    cmd("tool.attr mesh.sliceTool endZ 1");
    cmd("tool.doApply");
    cmd("tool.set mesh.sliceTool off");
    settle();
}

unittest { // 2 selected polygons (front + back) -> both halves of EACH stay selected (4 total)
    resetCube();
    assert(vertCount() == 8 && faceCount() == 6, "fresh cube must be 8v/6f");

    // Front (z=-0.5, face 0) + back (z=+0.5, face 1) — same faces the
    // slice_selection.json "restricted_two_faces" fixture case selects.
    selectPolygons([0, 1]);
    settle();
    assert(selCount("selectedFaces") == 2, "pre-cut selection of 2 faces must take");

    sliceXZeroInfinite();

    assert(vertCount() == 12 && faceCount() == 8,
           format("restricted cut of 2 selected faces must give 12v/8f, got %dv/%df",
                  vertCount(), faceCount()));

    // The fix: BOTH split halves of EACH selected parent stay selected.
    assert(selCount("selectedFaces") == 4,
           format("2 selected parents -> 4 selected halves after the cut, got %d",
                  selCount("selectedFaces")));
}

unittest { // nothing selected -> nothing selected after (selectNew-style negative)
    resetCube();
    assert(vertCount() == 8 && faceCount() == 6, "fresh cube must be 8v/6f");
    assert(selCount("selectedFaces") == 0, "fresh cube must have an empty face selection");

    sliceXZeroInfinite();

    assert(vertCount() == 12 && faceCount() == 10,
           format("whole (unrestricted) cut must give 12v/10f, got %dv/%df",
                  vertCount(), faceCount()));
    assert(selCount("selectedFaces") == 0,
           "nothing selected before the cut must still yield nothing selected after");
}

// A pinned work plane: the headless cut reads the one parameter frame
// (`primitivePlacementFrame`, task 9408). Ours, pinned law-neutrally. Plane
// rotX 30 about (0.2, 0.3, 0); a line along X cuts with normal line × plane
// normal = (0, -sin30, cos30), so the y = ±0.5 edges split at z = y·tan30
// (the world floor would split them at z = 0).
unittest { // pinned plane: the headless slice follows the plane's normal
    resetCube();
    cmd("workplane.reset");
    cmd("workplane.edit cenX:0.2 cenY:0.3 cenZ:0 rotX:30 rotY:0 rotZ:0");
    scope(exit) cmd("workplane.reset");
    cmd("tool.set mesh.sliceTool on");
    cmd("tool.attr mesh.sliceTool infinite 1");
    foreach (kv; [["startX", "-1"], ["startY", "0"], ["startZ", "0"],
                  ["endX", "1"], ["endY", "0"], ["endZ", "0"]])
        cmd("tool.attr mesh.sliceTool " ~ kv[0] ~ " " ~ kv[1]);
    cmd("tool.doApply");
    cmd("tool.set mesh.sliceTool off");
    settle();
    double num(JSONValue v) { return v.type == JSONType.integer ? v.integer : v.floating; }
    import std.math : fabs;
    auto vs = getModel()["vertices"].array;
    assert(vs.length == 12, format("pinned slice: expected 12 verts, got %d", vs.length));
    size_t onTilt;
    foreach (v; vs)
        if (fabs(fabs(num(v[1])) - 0.5) < 1e-4 && fabs(num(v[2]) - num(v[1]) * 0.57735027) < 1e-4)
            ++onTilt;
    assert(onTilt == 4, format("pinned slice: %d of the 4 new vertices on the tilted cut", onTilt));
}
