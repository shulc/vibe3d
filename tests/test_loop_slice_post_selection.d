// Post-tool selection for the interactive LoopSliceTool (factory id
// `mesh.loopSliceTool`) — task 0247.
//
// GOAL: pin down (and lock) WHAT selection remains after a Loop Slice cut
// commits / the tool applies. The reference "Select New Polygons" toggle
// (`selectNew`, panel default ON) governs this: with it ON the polygons
// created by the slice become the selection; with it OFF no new polygons
// are selected. vibe3d's kernel (`Mesh.insertEdgeLoopsMulti`) clears ALL
// selection at the end of a cut (`resetSelection()`), and the tool then
// re-selects the product iff `selectNew_`.
//
// TASK 1180 CHANGED WHAT "THE PRODUCT" IS HERE, on evidence this file did not
// have. The paragraph above used to end "...so the resulting selection is
// either the new FACES (default) or NOTHING, never the loop edges or the new
// vertices" — a description of OUR implementation, not a measurement; the only
// reference claim 0247 made was about the `selectNew` toggle itself. Dogfood
// ledger row 3 then measured the reference's post-slice selection with a
// THREE-LAYER readback and found the new loop's EDGES and VERTICES held
// ALONGSIDE the sliced faces (tests/fixtures/loop_slice_post_selection.json:
// 18 faces + 9 edges + 10 verts). So with `selectNew` on the selection is now
// the new faces PLUS the loop; with it off it is still nothing.
//
//   P1 — selectNew=true (default): after a count=1 cut on the cube's ring
//        crossed by seed edge 0-1, exactly the 8 new band faces are
//        selected, PLUS the loop itself — its 4 new midpoint vertices and
//        the 4 edges spanning them. Exact membership is pinned by geometry:
//        the 2 UNSELECTED faces are the two uncut caps (all 4 corners
//        original), every SELECTED face holds a new midpoint vertex, and the
//        selected edges are precisely those with BOTH endpoints new.
//   P2 — selectNew=false: the same cut leaves NOTHING selected (no faces,
//        no edges, no vertices) — the toggle's only job is whether the
//        product becomes the selection. This is the arm that says the new
//        edge/vertex leg rides the SAME toggle and is not unconditional.
//   P3 — Polygons-mode activation (task 0245): seeding from two adjacent
//        selected polygons keeps the selection TYPE at Polygon and leaves
//        the 8 new band faces (plus the loop) selected — the fully
//        consistent selType=polygon case. The type does NOT flip to edge or
//        vertex merely because those layers now carry a selection.

import http_client : testBaseUrl;
import std.net.curl;
import std.json;
import std.conv : to;
import std.math : abs, sqrt;
import std.algorithm : sort, canFind, all, any;

void main() {}

// --- HTTP helpers (same shapes as tests/test_loop_slice_tool.d) ------------

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
JSONValue getSelection() { return parseJSON(get(testBaseUrl() ~ "/api/selection")); }

// --- geometry helpers ------------------------------------------------------

struct V3 { double x, y, z; }

V3 vert(JSONValue m, size_t i) {
    auto a = m["vertices"].array[i].array;
    return V3(a[0].floating, a[1].floating, a[2].floating);
}

int edgeIndex(JSONValue m, int a, int b) {
    foreach (i, e; m["edges"].array) {
        int x = cast(int)e.array[0].integer;
        int y = cast(int)e.array[1].integer;
        if ((x == a && y == b) || (x == b && y == a)) return cast(int)i;
    }
    return -1;
}

// Task 1180: with `selectNew` on, the cut also leaves the LOOP selected — the
// new midpoint vertices and the edges spanning them. Pinned analytically, in
// this file's index-free style: "new" is "not an original cube corner", so the
// claim never mentions an index, and it is an IFF in both directions — an
// original corner that became selected fails just as loudly as a loop vertex
// that did not.
void assertLoopSelected(JSONValue m, JSONValue sel, string tag) {
    bool[int] selV;
    foreach (v; sel["selectedVertices"].array) selV[cast(int)v.integer] = true;
    foreach (vi; 0 .. m["vertices"].array.length) {
        immutable bool isNew = !isCornerVert(m, vi);
        immutable bool isSel = (cast(int)vi in selV) !is null;
        assert(isNew == isSel, tag ~ ": vertex " ~ vi.to!string
            ~ (isNew ? " is a new loop vertex and must be selected"
                     : " is an original corner and must NOT be selected"));
    }
    bool[int] selE;
    foreach (e; sel["selectedEdges"].array) selE[cast(int)e.integer] = true;
    foreach (ei; 0 .. m["edges"].array.length) {
        auto e = m["edges"].array[ei].array;
        immutable bool bothNew = !isCornerVert(m, cast(size_t)e[0].integer)
                              && !isCornerVert(m, cast(size_t)e[1].integer);
        immutable bool isSel   = (cast(int)ei in selE) !is null;
        assert(bothNew == isSel, tag ~ ": edge " ~ ei.to!string
            ~ (bothNew ? " lies inside the new loop and must be selected"
                       : " is not a loop edge and must NOT be selected"));
    }
}

int vertAt(JSONValue m, V3 p) {
    foreach (i; 0 .. m["vertices"].array.length) {
        auto v = vert(m, i);
        auto dx = v.x - p.x, dy = v.y - p.y, dz = v.z - p.z;
        if (sqrt(dx*dx + dy*dy + dz*dz) < 1e-4) return cast(int)i;
    }
    return -1;
}

// A vertex index that is an ORIGINAL cube corner (all coords ±0.5).
bool isCornerVert(JSONValue m, size_t vi) {
    auto v = vert(m, vi);
    return abs(abs(v.x) - 0.5) < 1e-4
        && abs(abs(v.y) - 0.5) < 1e-4
        && abs(abs(v.z) - 0.5) < 1e-4;
}

// The vertex indices of face `fi` (a list of ints in the model JSON).
size_t[] faceVerts(JSONValue m, size_t fi) {
    size_t[] r;
    foreach (v; m["faces"].array[fi].array) r ~= cast(size_t)v.integer;
    return r;
}

// The index of the equatorial seed edge 0-1 the mesh.d insertEdgeLoops
// unittests use: (-0.5,-0.5,-0.5) -> (0.5,-0.5,-0.5).
int seedEdge01(JSONValue m) {
    int va = vertAt(m, V3(-0.5, -0.5, -0.5));
    int vb = vertAt(m, V3( 0.5, -0.5, -0.5));
    assert(va >= 0 && vb >= 0, "cube verts 0/1 not found");
    int ei = edgeIndex(m, va, vb);
    assert(ei >= 0, "cube edge 0-1 not found");
    return ei;
}

// The face index whose 4 corners all share coordinate `val` on axis
// (0=x,1=y,2=z) — one of the six original cube faces.
int cubeFaceAtConst(JSONValue m, int axis, double val) {
    foreach (fi; 0 .. m["faces"].array.length) {
        bool allOn = true;
        foreach (vi; faceVerts(m, fi)) {
            auto v = vert(m, vi);
            double c = (axis == 0) ? v.x : (axis == 1) ? v.y : v.z;
            if (abs(c - val) > 1e-4) { allOn = false; break; }
        }
        if (allOn) return cast(int)fi;
    }
    return -1;
}

// ---------------------------------------------------------------------------
// P1. selectNew=true (default): the cut selects EXACTLY the 8 new band faces
//     — only faces, no edges, no vertices — and membership is the uncut-cap
//     complement (analytic, index-free).
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto before = getModel();
    postSelect("edges", [seedEdge01(before)]);

    cmd("tool.set mesh.loopSliceTool on");
    cmd("tool.attr mesh.loopSliceTool count 1");
    // default is on already; set explicitly to document the governing toggle.
    cmd("tool.attr mesh.loopSliceTool selectNew true");
    cmd("tool.doApply");

    auto after = getModel();
    assert(after["faceCount"].integer == 10, "expected 10 faces after one loop");

    auto sel = getSelection();
    // The remaining selection is the new faces AND the loop (task 1180, row 3).
    assertLoopSelected(after, sel, "post-cut");

    auto selFaces = sel["selectedFaces"].array;
    assert(selFaces.length == 8,
        "Select New Polygons: expected 8 selected faces, got "
        ~ selFaces.length.to!string);

    // Exact membership, pinned by geometry (index-free):
    //  - every SELECTED face is a new sub-quad → holds >=1 non-corner
    //    (midpoint) vertex;
    //  - the 2 UNSELECTED faces are the uncut caps → all 4 verts original
    //    corners.
    bool[size_t] selSet;
    foreach (f; selFaces) selSet[cast(size_t)f.integer] = true;
    foreach (fi; 0 .. after["faces"].array.length) {
        bool anyMid = false;
        foreach (vi; faceVerts(after, fi)) if (!isCornerVert(after, vi)) { anyMid = true; break; }
        if (cast(size_t)fi in selSet)
            assert(anyMid, "selected face " ~ fi.to!string
                ~ " must be a new sub-quad (hold a midpoint vertex)");
        else
            assert(!anyMid, "unselected face " ~ fi.to!string
                ~ " must be an uncut cap (all original corners)");
    }
}

// ---------------------------------------------------------------------------
// P2. selectNew=false: the SAME cut leaves NOTHING selected. The toggle's
//     only effect is whether the new polygons become the selection.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto before = getModel();
    postSelect("edges", [seedEdge01(before)]);

    cmd("tool.set mesh.loopSliceTool on");
    cmd("tool.attr mesh.loopSliceTool count 1");
    cmd("tool.attr mesh.loopSliceTool selectNew false");
    cmd("tool.doApply");

    auto after = getModel();
    assert(after["faceCount"].integer == 10,
        "selectNew=false still cuts: expected 10 faces");

    auto sel = getSelection();
    assert(sel["selectedFaces"].array.length == 0,
        "selectNew=false: no faces must be selected, got "
        ~ sel["selectedFaces"].array.length.to!string);
    assert(sel["selectedEdges"].array.length == 0,
        "selectNew=false: no edges must be selected");
    assert(sel["selectedVertices"].array.length == 0,
        "selectNew=false: no vertices must be selected");
}

// ---------------------------------------------------------------------------
// P3. Polygons-mode activation (task 0245): seeding from two ADJACENT
//     selected polygons cuts the ring crossing their shared edge; the
//     resulting selection is fully consistent — selType stays Polygon and
//     the 8 new band faces are selected (no edges/vertices). This is the
//     clean "selection type = polygon" case the reference leaves behind.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto before = getModel();
    // Front (z=-0.5) and Bottom (y=-0.5) are adjacent; their shared edge is
    // the equatorial seed edge 0-1, so the cut is the same x-perpendicular
    // ring as P1.
    int front  = cubeFaceAtConst(before, 2, -0.5);
    int bottom = cubeFaceAtConst(before, 1, -0.5);
    assert(front >= 0 && bottom >= 0, "cube front/bottom faces not found");
    postSelect("polygons", [front, bottom]);

    auto seedSel = getSelection();
    assert(seedSel["selType"].str == "polygon",
        "seed selType should be polygon, got " ~ seedSel["selType"].str);

    cmd("tool.set mesh.loopSliceTool on");
    cmd("tool.attr mesh.loopSliceTool count 1");
    cmd("tool.attr mesh.loopSliceTool selectNew true");
    cmd("tool.doApply");

    auto after = getModel();
    assert(after["faceCount"].integer == 10,
        "polygons-mode seed: expected 10 faces after one loop");

    auto sel = getSelection();
    assert(sel["selType"].str == "polygon",
        "post-cut selType must remain polygon, got " ~ sel["selType"].str);
    assert(sel["selectedFaces"].array.length == 8,
        "polygons-mode seed: expected 8 selected faces, got "
        ~ sel["selectedFaces"].array.length.to!string);
    assertLoopSelected(after, sel, "polygons-mode seed");
}
