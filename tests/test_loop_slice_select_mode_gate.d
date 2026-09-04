// Task 1054 review (SHOULD-FIX 1) -- `restrictFor` must consult the CURRENT
// edit mode, not just `sliceSelected_ && selFaces.length > 0`.
//
// Bug: a face selection made in Polygons mode SURVIVES a mode switch to
// Edges -- component selections are not cleared by a geometry-type switch
// (`commands/mesh/select.d`'s "edges" branch clears ONLY the edge
// selection). Before this fix, `restrictFor` activated band mode purely off
// `sliceSelected_ && selFaces.length > 0`, with no edit-mode check -- so
// arming Loop Slice in EDGES mode, with a genuine edge selection AND a
// stale face selection left over from Polygons mode, silently discarded the
// edge seeds: `insertEdgeLoopsMulti`'s `seeds` argument is UNUSED once band
// mode is entered (`bandFaces !is null`), so the cut walked the STALE
// selected faces instead of the edge ring the user actually selected.
//
// Fix: `restrictFor` now also requires `*editMode == EditMode.Polygons`, so
// a face selection surviving into Edges mode can never inject `bandFaces`.
//
// Drives the shared `restrictFor` helper through `tool.doApply`
// (`applyHeadless`) -- `tests/test_loop_slice_band_interactive.d`'s own
// header comment already establishes that `rebuildCut` (the interactive-arm
// path) and `applyHeadless` call the IDENTICAL kernel entry with the
// same-shaped `restrictFor(...)` argument, so covering `applyHeadless`
// covers the fixed code path for the interactive arm too.

import http_client : testBaseUrl;
import std.net.curl;
import std.json;
import std.conv : to;
import std.math : sqrt;

void main() {}

void resetCube() {
    auto resp = post(testBaseUrl() ~ "/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset failed: " ~ resp);
}

void cmd(string s) {
    auto resp = post(testBaseUrl() ~ "/api/command", s);
    assert(parseJSON(resp)["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ resp);
}

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto resp = post(testBaseUrl() ~ "/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok", "/api/select failed: " ~ resp);
}

JSONValue getModel() { return parseJSON(get(testBaseUrl() ~ "/api/model")); }

struct V3 { double x, y, z; }

V3 vert(JSONValue m, size_t i) {
    auto a = m["vertices"].array[i].array;
    return V3(a[0].floating, a[1].floating, a[2].floating);
}

int vertAt(JSONValue m, V3 p) {
    foreach (i; 0 .. m["vertices"].array.length) {
        auto v = vert(m, i);
        auto dx = v.x - p.x, dy = v.y - p.y, dz = v.z - p.z;
        if (sqrt(dx*dx + dy*dy + dz*dz) < 1e-4) return cast(int)i;
    }
    return -1;
}

int edgeIndex(JSONValue m, int a, int b) {
    foreach (i, e; m["edges"].array) {
        int x = cast(int)e.array[0].integer;
        int y = cast(int)e.array[1].integer;
        if ((x == a && y == b) || (x == b && y == a)) return cast(int)i;
    }
    return -1;
}

unittest {
    resetCube();
    auto m0 = getModel();

    // Stale face selection, made while in POLYGONS mode.
    postSelect("polygons", [0]);

    // Switch to EDGES mode and select the classic seed edge (0-1) -- same
    // edge the insertEdgeLoops mesh.d unittests and test_loop_slice_tool.d's
    // T1 use; ring-cuts 4 of the cube's 6 faces at the default position
    // (0.5): V=12, E=20, F=10. `postSelect("edges", ...)` clears only the
    // EDGE selection (commands/mesh/select.d) -- face 0 stays selected.
    int va = vertAt(m0, V3(-0.5, -0.5, -0.5));
    int vb = vertAt(m0, V3( 0.5, -0.5, -0.5));
    assert(va >= 0 && vb >= 0, "cube verts 0/1 not found");
    int ei = edgeIndex(m0, va, vb);
    assert(ei >= 0, "cube edge 0-1 not found");
    postSelect("edges", [ei]);

    cmd("tool.set mesh.loopSliceTool on");
    // Pin count/position explicitly -- sticky tool defaults from an earlier
    // test in the same worker process must not change the expected V/E/F.
    cmd("tool.attr mesh.loopSliceTool count 1");
    cmd("tool.attr mesh.loopSliceTool position 0.5");
    cmd("tool.attr mesh.loopSliceTool select 1");   // Slice Selected ON
    cmd("tool.doApply");

    auto after = getModel();
    // The classic single-ring cut through edge 0-1 -- proves the EDGE seeds
    // were honoured and band mode (which would instead have walked the
    // STALE 1-face selection, producing a completely different V/E/F -- a
    // single face split in two, not a 4-face ring) was never entered.
    assert(after["vertexCount"].integer == 12,
        "expected the classic ring-cut vertex count (12), got "
        ~ after["vertexCount"].integer.to!string
        ~ " -- a stale Polygons-mode face selection leaked into Edges-mode "
        ~ "band activation");
    assert(after["edgeCount"].integer == 20,
        "expected the classic ring-cut edge count (20), got "
        ~ after["edgeCount"].integer.to!string);
    assert(after["faceCount"].integer == 10,
        "expected the classic ring-cut face count (10), got "
        ~ after["faceCount"].integer.to!string);
}
